use chrono::{DateTime, NaiveDate, Utc};
use serde::Deserialize;
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};
use crate::{copilot_auth, paths};

/// Reads the monthly quotas GitHub reports to the Copilot editor plugins.
///
/// The token is the GitHub OAuth token from signing in through the notch, or
/// failing that one another Copilot client already saved: VS Code keeps its
/// own in the keyring, so the files below are the ones Neovim, JetBrains and
/// opencode leave behind.
pub struct CopilotProvider;

const USER_ENDPOINT: &str = "https://api.github.com/copilot_internal/user";

impl Provider for CopilotProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Copilot
    }
}

impl CopilotProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let tokens = read_tokens();
        if tokens.is_empty() {
            return Err(ProviderError::NeedsAuth(
                "Not signed in — sign in to GitHub Copilot from Settings".into(),
            ));
        }

        let client = client()?;

        // Several clients may be signed in; a revoked token in one should not
        // hide a good one in another.
        for token in &tokens {
            let Some(account) = fetch_account(&client, token).await? else {
                continue;
            };
            return Ok(account.into_reading(Utc::now()));
        }

        Err(ProviderError::NeedsAuth(
            "Copilot sign-in expired or has no Copilot access — sign in again from Settings".into(),
        ))
    }
}

/// A GitHub client, as the Copilot plugin endpoints expect it.
pub(crate) fn client() -> Result<reqwest::Client, ProviderError> {
    reqwest::Client::builder()
        .user_agent("GitHubCopilotChat/0.26.7")
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| ProviderError::Other(e.into()))
}

/// The token's quotas, or `None` when GitHub does not recognize it.
pub(crate) async fn fetch_account(
    client: &reqwest::Client,
    token: &str,
) -> Result<Option<CopilotAccount>, ProviderError> {
    let response = client
        .get(USER_ENDPOINT)
        .header("Authorization", format!("token {token}"))
        .header("Accept", "application/json")
        .header("Editor-Version", "vscode/1.99.0")
        .header("Editor-Plugin-Version", "copilot-chat/0.26.7")
        .header("X-GitHub-Api-Version", "2025-04-01")
        .send()
        .await
        .map_err(|e| ProviderError::Other(e.into()))?;

    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED
        || status == reqwest::StatusCode::FORBIDDEN
        || status == reqwest::StatusCode::NOT_FOUND
    {
        return Ok(None);
    }
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(ProviderError::Message(format!(
            "Copilot usage HTTP {status}: {body}"
        )));
    }

    let user: CopilotUser = response
        .json()
        .await
        .map_err(|e| ProviderError::Other(e.into()))?;
    let (windows, plan) = user.parts();
    Ok(Some(CopilotAccount { windows, plan }))
}

pub(crate) struct CopilotAccount {
    pub windows: Vec<UsageWindow>,
    pub plan: Option<String>,
}

impl CopilotAccount {
    fn into_reading(self, now: DateTime<Utc>) -> UsageReading {
        UsageReading {
            provider: ProviderId::Copilot,
            display_name: ProviderId::Copilot.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Ok,
            windows: self.windows,
            fetched_at: now,
            message: self.plan.map(|plan| format!("Copilot {plan} plan")),
        }
    }
}

/// Our own sign-in first, then every GitHub OAuth token a Copilot client left
/// on disk, newest format first.
fn read_tokens() -> Vec<String> {
    let mut tokens = Vec::new();
    if let Some(token) = copilot_auth::saved_token() {
        push_token(&mut tokens, Some(&Value::String(token)));
    }
    let dir = paths::github_copilot_dir();

    // `apps.json`: {"github.com:<app id>": {"user", "oauth_token", …}}
    // `hosts.json`: {"github.com": {"user", "oauth_token"}}
    for name in ["apps.json", "hosts.json"] {
        if let Some(value) = read_json(&dir.join(name)) {
            if let Some(map) = value.as_object() {
                for (host, entry) in map {
                    if host.starts_with("github.com") {
                        push_token(&mut tokens, entry.get("oauth_token"));
                    }
                }
            }
        }
    }

    // opencode: {"github-copilot": {"type": "oauth", "refresh": <token>, …}}
    if let Some(value) = read_json(&paths::opencode_auth()) {
        push_token(&mut tokens, value.pointer("/github-copilot/refresh"));
    }

    tokens
}

fn read_json(path: &std::path::Path) -> Option<Value> {
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

fn push_token(tokens: &mut Vec<String>, value: Option<&Value>) {
    if let Some(token) = value.and_then(Value::as_str).map(str::trim) {
        if !token.is_empty() && !tokens.iter().any(|t| t == token) {
            tokens.push(token.to_string());
        }
    }
}

#[derive(Debug, Deserialize)]
struct CopilotUser {
    copilot_plan: Option<String>,
    quota_reset_date_utc: Option<String>,
    quota_reset_date: Option<String>,
    quota_snapshots: Option<QuotaSnapshots>,
    /// Free plan: what is left of each monthly allowance…
    limited_user_quotas: Option<FreeQuotas>,
    /// …out of these totals.
    monthly_quotas: Option<FreeQuotas>,
    limited_user_reset_date: Option<String>,
}

#[derive(Debug, Deserialize)]
struct QuotaSnapshots {
    premium_interactions: Option<QuotaSnapshot>,
    chat: Option<QuotaSnapshot>,
    completions: Option<QuotaSnapshot>,
}

#[derive(Debug, Deserialize)]
struct QuotaSnapshot {
    entitlement: Option<f64>,
    remaining: Option<f64>,
    percent_remaining: Option<f64>,
    unlimited: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct FreeQuotas {
    chat: Option<f64>,
    completions: Option<f64>,
}

impl QuotaSnapshot {
    fn used_pct(&self) -> Option<f64> {
        if self.unlimited == Some(true) {
            return None;
        }
        let pct = match (self.percent_remaining, self.entitlement, self.remaining) {
            (Some(left), _, _) => 100.0 - left,
            (None, Some(total), Some(left)) if total > 0.0 => (total - left) / total * 100.0,
            _ => return None,
        };
        Some(pct.clamp(0.0, 100.0))
    }
}

impl CopilotUser {
    /// The quota windows and the plan's name, for any reader of the API.
    fn parts(self) -> (Vec<UsageWindow>, Option<String>) {
        let resets_at = self
            .quota_reset_date_utc
            .as_deref()
            .and_then(parse_rfc3339)
            .or_else(|| self.quota_reset_date.as_deref().and_then(parse_date))
            .or_else(|| self.limited_user_reset_date.as_deref().and_then(parse_date));

        let mut windows = Vec::new();

        if let Some(snapshots) = &self.quota_snapshots {
            for (snapshot, label) in [
                (&snapshots.premium_interactions, "Premium requests"),
                (&snapshots.chat, "Chat"),
                (&snapshots.completions, "Completions"),
            ] {
                if let Some(pct) = snapshot.as_ref().and_then(QuotaSnapshot::used_pct) {
                    windows.push(UsageWindow {
                        label: label.into(),
                        used_pct: pct,
                        resets_at,
                    });
                }
            }
        }

        if windows.is_empty() {
            if let (Some(left), Some(total)) = (&self.limited_user_quotas, &self.monthly_quotas) {
                for (left, total, label) in [
                    (left.chat, total.chat, "Chat"),
                    (left.completions, total.completions, "Completions"),
                ] {
                    if let (Some(left), Some(total)) = (left, total) {
                        if total > 0.0 {
                            windows.push(UsageWindow {
                                label: label.into(),
                                used_pct: ((total - left) / total * 100.0).clamp(0.0, 100.0),
                                resets_at,
                            });
                        }
                    }
                }
            }
        }

        if windows.is_empty() {
            windows.push(UsageWindow {
                label: "Premium requests".into(),
                used_pct: 0.0,
                resets_at,
            });
        }

        (windows, self.copilot_plan)
    }
}

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn parse_date(s: &str) -> Option<DateTime<Utc>> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .ok()?
        .and_hms_opt(0, 0, 0)
        .map(|dt| dt.and_utc())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(raw: &str) -> UsageReading {
        let user: CopilotUser = serde_json::from_str(raw).unwrap();
        let (windows, plan) = user.parts();
        CopilotAccount { windows, plan }.into_reading(Utc::now())
    }

    #[test]
    fn paid_plan_leads_with_premium_requests() {
        let r = reading(
            r#"{"copilot_plan":"individual","quota_reset_date":"2026-10-01",
                "quota_reset_date_utc":"2026-10-01T00:00:00.000Z",
                "quota_snapshots":{
                  "chat":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true},
                  "completions":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true},
                  "premium_interactions":{"entitlement":300,"remaining":210,"percent_remaining":70.0,"unlimited":false}}}"#,
        );
        assert_eq!(r.windows.len(), 1);
        assert_eq!(r.windows[0].label, "Premium requests");
        assert!((r.windows[0].used_pct - 30.0).abs() < 1e-9);
        assert_eq!(
            r.windows[0].resets_at,
            Some(parse_rfc3339("2026-10-01T00:00:00Z").unwrap())
        );
        assert_eq!(r.message.as_deref(), Some("Copilot individual plan"));
    }

    #[test]
    fn overage_is_capped_at_full() {
        let r = reading(
            r#"{"quota_snapshots":{"premium_interactions":
                {"entitlement":300,"remaining":-12,"percent_remaining":-4.0,"unlimited":false}}}"#,
        );
        assert_eq!(r.windows[0].used_pct, 100.0);
    }

    #[test]
    fn free_plan_uses_monthly_quotas() {
        let r = reading(
            r#"{"copilot_plan":"free","limited_user_reset_date":"2026-10-12",
                "limited_user_quotas":{"chat":40,"completions":1500},
                "monthly_quotas":{"chat":50,"completions":2000}}"#,
        );
        assert_eq!(r.windows[0].label, "Chat");
        assert!((r.windows[0].used_pct - 20.0).abs() < 1e-9);
        assert_eq!(r.windows[1].label, "Completions");
        assert!((r.windows[1].used_pct - 25.0).abs() < 1e-9);
        assert_eq!(r.windows[0].resets_at, parse_date("2026-10-12"));
    }
}
