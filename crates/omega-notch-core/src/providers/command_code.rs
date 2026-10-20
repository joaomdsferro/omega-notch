use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

const API: &str = "https://api.commandcode.ai/alpha";

pub struct CommandCodeProvider;

impl Provider for CommandCodeProvider {
    fn id(&self) -> ProviderId {
        ProviderId::CommandCode
    }
}

impl CommandCodeProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let token = read_token(&paths::command_code_auth())?;

        let whoami = self.get(&format!("{API}/whoami"), &token).await?;
        let org_id = whoami
            .pointer("/org/id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();

        let credits = self
            .get(
                &with_query(
                    &format!("{API}/billing/credits"),
                    &[("orgId", org_id.as_str())],
                ),
                &token,
            )
            .await?;
        let subscription = self
            .get(
                &with_query(
                    &format!("{API}/billing/subscriptions"),
                    &[("orgId", org_id.as_str())],
                ),
                &token,
            )
            .await?;

        let sub = subscription.get("data").unwrap_or(&subscription);
        let since = sub
            .get("currentPeriodStart")
            .and_then(parse_date)
            .map(|at| at.to_rfc3339_opts(SecondsFormat::Secs, true));

        let mut summary_query = vec![("orgId", org_id.as_str())];
        if let Some(since) = since.as_deref() {
            summary_query.push(("since", since));
        }
        let summary = self
            .get(
                &with_query(&format!("{API}/usage/summary"), &summary_query),
                &token,
            )
            .await?;

        parse_usage(&summary, &credits, &subscription)
    }

    async fn get(&self, url: &str, token: &str) -> Result<Value, ProviderError> {
        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .get(url)
            .bearer_auth(token)
            .header("x-command-code-version", "desktop")
            .header("accept", "application/json")
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 | 403 => {
                return Err(ProviderError::NeedsAuth(
                    "Command Code rejected the key — sign in again in Command Code".into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Command Code rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "Command Code usage HTTP {status}: {body}"
                )));
            }
            _ => {}
        }

        response
            .json()
            .await
            .map_err(|e| ProviderError::Other(e.into()))
    }
}

/// `~/.commandcode/auth.json`, the file the desktop app writes on login.
/// `COMMAND_CODE_API_KEY` wins when set, as in the desktop harness.
fn read_token(path: &std::path::Path) -> Result<String, ProviderError> {
    if let Some(key) = std::env::var("COMMAND_CODE_API_KEY")
        .ok()
        .map(|key| key.trim().to_string())
        .filter(|key| !key.is_empty())
    {
        return Ok(key);
    }

    let raw = std::fs::read_to_string(path).map_err(|_| {
        ProviderError::NeedsAuth(
            "No Command Code sign-in — sign in in Command Code or set COMMAND_CODE_API_KEY".into(),
        )
    })?;
    let root: Value = serde_json::from_str(&raw).map_err(|e| ProviderError::Other(e.into()))?;
    root.get("apiKey")
        .and_then(Value::as_str)
        .filter(|key| !key.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            ProviderError::NeedsAuth("~/.commandcode/auth.json has no key — sign in again".into())
        })
}

fn with_query(base: &str, items: &[(&str, &str)]) -> String {
    let query: Vec<String> = items
        .iter()
        .filter(|(key, value)| !key.is_empty() && !value.is_empty())
        .map(|(key, value)| format!("{}={}", percent_encode(key), percent_encode(value)))
        .collect();
    if query.is_empty() {
        base.to_string()
    } else {
        format!("{base}?{}", query.join("&"))
    }
}

fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn parse_usage(
    summary: &Value,
    credits: &Value,
    subscription: &Value,
) -> Result<UsageReading, ProviderError> {
    let used = summary
        .get("totalCost")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let remaining = credits
        .pointer("/credits/monthlyCredits")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let cap = used + remaining;
    if cap <= 0.0 {
        return Err(ProviderError::Message(
            "Command Code has nothing metered on this account yet".into(),
        ));
    }

    let sub = subscription.get("data").unwrap_or(subscription);
    let period_end = sub.get("currentPeriodEnd").and_then(parse_date);

    let mut windows = vec![UsageWindow {
        label: "Monthly limit".into(),
        used_pct: (used / cap * 100.0).clamp(0.0, 100.0),
        resets_at: period_end,
    }];

    let limits = credits.get("windowLimits").unwrap_or(&Value::Null);
    for (key, label) in [("fiveHour", "5h limit"), ("weekly", "Weekly limit")] {
        let Some(entry) = limits.get(key) else {
            continue;
        };
        let cap = entry.get("cap").and_then(Value::as_f64).unwrap_or(0.0);
        if cap <= 0.0 {
            continue;
        }
        let used = entry.get("used").and_then(Value::as_f64).unwrap_or(0.0);
        windows.push(UsageWindow {
            label: label.into(),
            used_pct: (used / cap * 100.0).clamp(0.0, 100.0),
            resets_at: entry.get("resetAt").and_then(parse_date),
        });
    }

    Ok(UsageReading {
        provider: ProviderId::CommandCode,
        display_name: ProviderId::CommandCode.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: None,
    })
}

/// ISO 8601, unix seconds, or unix milliseconds. Zero is "no reset".
fn parse_date(value: &Value) -> Option<DateTime<Utc>> {
    if let Some(text) = value.as_str() {
        return DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|dt| dt.with_timezone(&Utc));
    }
    let mut unix = value.as_f64()?;
    if unix <= 0.0 {
        return None;
    }
    if unix > 1_000_000_000_000.0 {
        unix /= 1000.0;
    }
    DateTime::from_timestamp(unix as i64, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_monthly_cap_and_the_shorter_windows() {
        let summary = serde_json::json!({"totalCost": 12.0, "totalCount": 40});
        let credits = serde_json::json!({
            "credits": {"monthlyCredits": 8.0},
            "windowLimits": {
                "fiveHour": {"cap": 10, "used": 2, "resetAt": 0},
                "weekly": {"cap": 50, "used": 25, "resetAt": 1795000000}
            }
        });
        let subscription = serde_json::json!({"data": {"planId": "goat", "currentPeriodEnd": "2026-11-01T00:00:00Z"}});
        let reading = parse_usage(&summary, &credits, &subscription).unwrap();
        assert_eq!(reading.windows.len(), 3);
        assert!((reading.windows[0].used_pct - 60.0).abs() < 0.001);
        assert!(reading.windows[0].resets_at.is_some());
        assert!((reading.windows[1].used_pct - 20.0).abs() < 0.001);
        assert!(reading.windows[1].resets_at.is_none());
        assert!((reading.windows[2].used_pct - 50.0).abs() < 0.001);
    }

    #[test]
    fn nothing_metered_is_an_error_not_a_zero() {
        let reading = parse_usage(
            &serde_json::json!({}),
            &serde_json::json!({}),
            &serde_json::json!({}),
        );
        assert!(reading.is_err());
    }
}
