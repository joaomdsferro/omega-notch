use chrono::{DateTime, TimeZone, Utc};
use serde::Deserialize;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

/// Rate limits for Codex (CLI, IDE extension and the ChatGPT/Codex desktop app).
///
/// Same endpoint the Codex CLI's `/status` reads, signed in with the ChatGPT
/// tokens Codex keeps in `~/.codex/auth.json`. The file is only read: Codex
/// rotates the refresh token itself, so refreshing here would sign it out.
pub struct CodexProvider;

const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";

impl Provider for CodexProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Codex
    }
}

impl CodexProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let auth = read_auth()?;

        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let mut request = client.get(USAGE_URL).bearer_auth(&auth.access_token);
        if let Some(account) = &auth.account_id {
            request = request.header("ChatGPT-Account-Id", account);
        }
        let response = request
            .send()
            .await
            .map_err(|e| ProviderError::Message(format!("Codex usage request failed: {}", e.without_url())))?;

        if response.status() == reqwest::StatusCode::UNAUTHORIZED
            || response.status() == reqwest::StatusCode::FORBIDDEN
        {
            return Err(ProviderError::NeedsAuth(
                "Codex sign-in expired — open Codex to refresh it".into(),
            ));
        }

        if !response.status().is_success() {
            return Err(ProviderError::Message(format!(
                "Codex usage HTTP {}",
                response.status()
            )));
        }

        let payload: UsagePayload = response
            .json()
            .await
            .map_err(|e| ProviderError::Message(format!("Codex usage: {e}")))?;

        Ok(payload.into_reading())
    }
}

struct CodexAuth {
    access_token: String,
    account_id: Option<String>,
}

/// Pulls the ChatGPT access token out of `~/.codex/auth.json`. Parse errors are
/// reported without serde's detail, which can quote the file's contents.
fn read_auth() -> Result<CodexAuth, ProviderError> {
    #[derive(Deserialize)]
    struct AuthFile {
        auth_mode: Option<String>,
        tokens: Option<Tokens>,
    }
    #[derive(Deserialize)]
    struct Tokens {
        access_token: Option<String>,
        account_id: Option<String>,
    }

    let path = paths::codex_auth();
    let raw = std::fs::read_to_string(&path).map_err(|_| {
        ProviderError::NeedsAuth("Sign in to Codex with your ChatGPT account".into())
    })?;
    let file: AuthFile = serde_json::from_str(&raw)
        .map_err(|_| ProviderError::Message("Could not parse ~/.codex/auth.json".into()))?;

    if file.auth_mode.as_deref().is_some_and(|m| m.eq_ignore_ascii_case("apikey")) {
        return Err(ProviderError::NeedsAuth(
            "Codex uses an API key — limits exist only with a ChatGPT sign-in".into(),
        ));
    }

    let tokens = file.tokens.ok_or_else(|| {
        ProviderError::NeedsAuth("Sign in to Codex with your ChatGPT account".into())
    })?;
    let access_token = tokens
        .access_token
        .filter(|t| !t.is_empty())
        .ok_or_else(|| ProviderError::NeedsAuth("Sign in to Codex with your ChatGPT account".into()))?;

    Ok(CodexAuth {
        access_token,
        account_id: tokens.account_id.filter(|a| !a.is_empty()),
    })
}

#[derive(Debug, Default, Deserialize)]
struct UsagePayload {
    plan_type: Option<String>,
    rate_limit: Option<RateLimit>,
}

#[derive(Debug, Default, Deserialize)]
struct RateLimit {
    #[serde(default)]
    limit_reached: bool,
    primary_window: Option<Window>,
    secondary_window: Option<Window>,
}

#[derive(Debug, Deserialize)]
struct Window {
    used_percent: Option<f64>,
    limit_window_seconds: Option<i64>,
    reset_after_seconds: Option<i64>,
    reset_at: Option<i64>,
}

impl Window {
    fn into_usage(self, fallback_label: &str, now: DateTime<Utc>) -> UsageWindow {
        let resets_at = self
            .reset_at
            .and_then(|ts| Utc.timestamp_opt(ts, 0).single())
            .or_else(|| {
                self.reset_after_seconds
                    .map(|s| now + chrono::Duration::seconds(s))
            });
        UsageWindow {
            label: self
                .limit_window_seconds
                .map(window_label)
                .unwrap_or_else(|| fallback_label.to_string()),
            used_pct: self.used_percent.unwrap_or(0.0).clamp(0.0, 100.0),
            resets_at,
        }
    }
}

/// "5h" for the session window, "Weekly"/"Monthly" for the long ones (Free
/// plans get a single 30-day window), else the length.
fn window_label(seconds: i64) -> String {
    const HOUR: i64 = 3600;
    const DAY: i64 = 24 * HOUR;
    match seconds {
        s if s == 7 * DAY => "Weekly".into(),
        s if s == 30 * DAY => "Monthly".into(),
        s if s >= DAY && s % DAY == 0 => format!("{}d", s / DAY),
        s if s >= HOUR => format!("{}h", (s + HOUR / 2) / HOUR),
        s => format!("{}m", (s / 60).max(1)),
    }
}

impl UsagePayload {
    fn into_reading(self) -> UsageReading {
        let now = Utc::now();
        let rate = self.rate_limit.unwrap_or_default();
        let windows: Vec<UsageWindow> = [
            rate.primary_window.map(|w| w.into_usage("5h", now)),
            rate.secondary_window.map(|w| w.into_usage("Weekly", now)),
        ]
        .into_iter()
        .flatten()
        .collect();

        let plan = self
            .plan_type
            .filter(|p| !p.trim().is_empty())
            .map(|p| plan_label(p.trim()));
        let message = match (rate.limit_reached, plan) {
            (true, Some(plan)) => Some(format!("{plan} · limit reached")),
            (true, None) => Some("Limit reached".to_string()),
            (false, plan) if windows.is_empty() => {
                Some(plan.map_or("No usage limits reported".into(), |p| format!("{p} · no limits reported")))
            }
            (false, plan) => plan,
        };

        UsageReading {
            provider: ProviderId::Codex,
            display_name: ProviderId::Codex.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Ok,
            windows,
            fetched_at: now,
            message,
        }
    }
}

fn plan_label(plan: &str) -> String {
    let mut chars = plan.chars();
    match chars.next() {
        Some(first) => format!("ChatGPT {}{}", first.to_uppercase(), chars.as_str()),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_session_and_weekly_windows() {
        let raw = r#"{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
            "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":600,"reset_at":1791374400},
            "secondary_window":{"used_percent":40.5,"limit_window_seconds":604800,"reset_after_seconds":9000,"reset_at":1791900000}}}"#;
        let reading = serde_json::from_str::<UsagePayload>(raw).unwrap().into_reading();
        assert_eq!(reading.windows.len(), 2);
        assert_eq!(reading.windows[0].label, "5h");
        assert_eq!(reading.windows[0].used_pct, 12.0);
        assert_eq!(reading.windows[0].resets_at.unwrap().timestamp(), 1791374400);
        assert_eq!(reading.windows[1].label, "Weekly");
        assert!((reading.windows[1].used_pct - 40.5).abs() < 1e-9);
        assert_eq!(reading.message.as_deref(), Some("ChatGPT Plus"));
    }

    #[test]
    fn missing_rate_limit_has_no_windows() {
        let reading = serde_json::from_str::<UsagePayload>(r#"{"plan_type":"free"}"#)
            .unwrap()
            .into_reading();
        assert!(reading.windows.is_empty());
        assert_eq!(reading.message.as_deref(), Some("ChatGPT Free · no limits reported"));
    }

    #[test]
    fn labels_window_lengths() {
        assert_eq!(window_label(18000), "5h");
        assert_eq!(window_label(604800), "Weekly");
        assert_eq!(window_label(2_592_000), "Monthly");
        assert_eq!(window_label(86400), "1d");
    }
}
