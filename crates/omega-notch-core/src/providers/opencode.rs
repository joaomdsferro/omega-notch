use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::opencode::{self, RecentUsage};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};
use crate::USER_AGENT;

/// opencode, the TUI agent. Its sessions, messages and token counts are all
/// in its local SQLite database, which names the sub-provider — Zen,
/// Anthropic, GitHub Copilot… — that billed each turn. When that
/// sub-provider has a usage API the notch knows (Anthropic, Copilot), the
/// ring shows its limits; Zen has none, so the ring says what the local
/// database holds instead.
pub struct OpenCodeProvider;

const ANTHROPIC_USAGE: &str = "https://api.anthropic.com/api/oauth/usage";

impl Provider for OpenCodeProvider {
    fn id(&self) -> ProviderId {
        ProviderId::OpenCode
    }
}

impl OpenCodeProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let Some(usage) = opencode::recent_usage() else {
            return Err(ProviderError::NeedsAuth(
                "No OpenCode usage yet — run opencode once, then check back".into(),
            ));
        };
        match usage.sub_provider.as_str() {
            "anthropic" => Ok(fetch_anthropic().await.map_or_else(
                || derived(&usage, Some("Anthropic limits unavailable")),
                |windows| reading(windows, None),
            )),
            "github-copilot" => Ok(fetch_copilot().await.map_or_else(
                || derived(&usage, None),
                |(windows, plan)| {
                    reading(
                        windows,
                        plan.map(|plan| format!("GitHub Copilot {plan} plan · via opencode")),
                    )
                },
            )),
            _ => Ok(derived(&usage, None)),
        }
    }
}

fn reading(windows: Vec<UsageWindow>, message: Option<String>) -> UsageReading {
    UsageReading {
        provider: ProviderId::OpenCode,
        display_name: ProviderId::OpenCode.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message,
    }
}

/// The local database knows the size of the week but no published limits.
fn derived(usage: &RecentUsage, note: Option<&str>) -> UsageReading {
    let totals = format!(
        "{} tokens in 7 days",
        opencode::compact_tokens(usage.week.total())
    );
    let base = match usage.top_models.first() {
        Some((model, _)) => format!("{totals}, mostly {model}"),
        None => totals,
    };
    let message = match note {
        Some(note) => format!("{note} — local data only: {base}"),
        None if usage.sub_provider == "opencode" => {
            format!("No usage API for opencode zen — local data only: {base}")
        }
        None => format!("Local data only: {base}"),
    };
    UsageReading {
        provider: ProviderId::OpenCode,
        display_name: ProviderId::OpenCode.display_name().to_string(),
        fidelity: Fidelity::Derived,
        status: ReadingStatus::Ok,
        windows: vec![],
        fetched_at: Utc::now(),
        message: Some(message),
    }
}

/// The Anthropic limits for opencode's own Anthropic sign-in; `None` when
/// there is none or it is stale.
async fn fetch_anthropic() -> Option<Vec<UsageWindow>> {
    let token = anthropic_token()?;
    let client = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(20))
        .build()
        .ok()?;
    let response = client
        .get(ANTHROPIC_USAGE)
        .bearer_auth(&token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: Value = response.json().await.ok()?;
    let windows = anthropic_windows(&body);
    (!windows.is_empty()).then_some(windows)
}

fn anthropic_windows(body: &Value) -> Vec<UsageWindow> {
    let bucket = |label: &str, key: &str| -> Option<UsageWindow> {
        let bucket = body.get(key)?;
        Some(UsageWindow {
            label: label.into(),
            used_pct: bucket
                .get("utilization")
                .and_then(Value::as_f64)
                .unwrap_or(0.0)
                .clamp(0.0, 100.0),
            resets_at: bucket
                .get("resets_at")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339),
        })
    };
    let mut windows: Vec<UsageWindow> = [
        bucket("Current session", "five_hour"),
        bucket("Weekly limit", "seven_day"),
    ]
    .into_iter()
    .flatten()
    .collect();
    if windows.is_empty() {
        if let Some(limits) = body.get("limits").and_then(Value::as_array) {
            for limit in limits {
                let label = match limit.get("kind").and_then(Value::as_str) {
                    Some("session") => "Current session",
                    Some("weekly_all") => "Weekly limit",
                    Some(other) => other,
                    None => continue,
                };
                windows.push(UsageWindow {
                    label: label.into(),
                    used_pct: limit
                        .get("percent")
                        .and_then(Value::as_f64)
                        .unwrap_or(0.0)
                        .clamp(0.0, 100.0),
                    resets_at: limit
                        .get("resets_at")
                        .and_then(Value::as_str)
                        .and_then(parse_rfc3339),
                });
            }
        }
    }
    windows
}

/// The Copilot quotas of opencode's own GitHub sign-in.
async fn fetch_copilot() -> Option<(Vec<UsageWindow>, Option<String>)> {
    let token = copilot_token()?;
    let client = super::copilot::client().ok()?;
    let account = super::copilot::fetch_account(&client, &token)
        .await
        .ok()
        .flatten()?;
    Some((account.windows, account.plan))
}

fn anthropic_token() -> Option<String> {
    // auth.json: {"anthropic": {"type": "oauth", "access": "sk-ant-oat…"}}
    if let Some(value) = read_json(&paths::opencode_auth()) {
        if let Some(token) = token_from(&value, "/anthropic") {
            return Some(token);
        }
    }
    credential_tokens("anthropic").into_iter().next()
}

fn copilot_token() -> Option<String> {
    // auth.json: {"github-copilot": {"type": "oauth", "refresh": <token>}}
    if let Some(value) = read_json(&paths::opencode_auth()) {
        if let Some(token) = value
            .pointer("/github-copilot/refresh")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|token| !token.is_empty())
        {
            return Some(token.to_string());
        }
    }
    credential_tokens("github-copilot").into_iter().next()
}

/// Newer opencode keeps signed-in integrations in its SQLite `credential`
/// table; the JSON shape is not documented, so accept the usual fields.
fn credential_tokens(integration: &str) -> Vec<String> {
    let Some(conn) = opencode::read_connection() else {
        return Vec::new();
    };
    let Ok(mut statement) =
        conn.prepare("SELECT value FROM credential WHERE integration_id = ?1 AND active = 1")
    else {
        return Vec::new();
    };
    let rows = statement.query_map([integration], |row| row.get::<_, Option<String>>(0));
    let Ok(rows) = rows else {
        return Vec::new();
    };
    rows.flatten()
        .flatten()
        .filter_map(|raw| {
            let value: Value = serde_json::from_str(&raw).unwrap_or(Value::String(raw));
            token_from(&value, "")
        })
        .collect()
}

/// An OAuth access token inside an integration entry: a bare string value
/// counts, objects are checked for the usual field names. API keys can't
/// read usage, so entries that say they are keys are no use.
fn token_from(value: &Value, pointer: &str) -> Option<String> {
    let entry = if pointer.is_empty() {
        Some(value)
    } else {
        value.pointer(pointer)
    }?;
    if let Some(token) = entry
        .as_str()
        .map(str::trim)
        .filter(|token| !token.is_empty())
    {
        return Some(token.to_string());
    }
    if entry.get("type").and_then(Value::as_str) == Some("api") {
        return None;
    }
    ["access", "access_token", "token"].iter().find_map(|key| {
        entry
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .map(str::to_string)
    })
}

fn read_json(path: &std::path::Path) -> Option<Value> {
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anthropic_buckets_become_windows() {
        let body: Value = serde_json::from_str(
            r#"{"five_hour":{"utilization":45.0,"resets_at":"2026-10-01T18:50:00Z"},
                "seven_day":{"utilization":55.5,"resets_at":null}}"#,
        )
        .unwrap();
        let windows = anthropic_windows(&body);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "Current session");
        assert!((windows[0].used_pct - 45.0).abs() < 1e-9);
        assert!(windows[0].resets_at.is_some());
        assert_eq!(windows[1].label, "Weekly limit");
    }

    #[test]
    fn anthropic_limits_array_is_the_fallback() {
        let body: Value = serde_json::from_str(
            r#"{"limits":[{"kind":"session","percent":81.5,"resets_at":"2026-10-01T18:50:00Z"},
                {"kind":"weekly_all","percent":10}]}"#,
        )
        .unwrap();
        let windows = anthropic_windows(&body);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "Current session");
        assert!((windows[0].used_pct - 81.5).abs() < 1e-9);
        assert!(windows[1].resets_at.is_none());
    }

    #[test]
    fn tokens_come_from_the_usual_credential_fields() {
        let entry: Value =
            serde_json::from_str(r#"{"type":"oauth","access":"sk-ant-oat-1","refresh":"r"}"#)
                .unwrap();
        let value = serde_json::json!({ "anthropic": entry });
        assert_eq!(
            token_from(&value, "/anthropic").as_deref(),
            Some("sk-ant-oat-1")
        );
        let key: Value = serde_json::from_str(r#"{"type":"api","key":"sk-ant-api-1"}"#).unwrap();
        assert_eq!(token_from(&key, ""), None);
        assert_eq!(
            token_from(&Value::String("gho_token".into()), "").as_deref(),
            Some("gho_token")
        );
    }
}
