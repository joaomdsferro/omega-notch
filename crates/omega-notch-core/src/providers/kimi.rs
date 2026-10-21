use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

/// The endpoint the CLI's own `/usage` asks.
const USAGES_URL: &str = "https://api.kimi.com/coding/v1/usages";

pub struct KimiProvider;

impl Provider for KimiProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Kimi
    }
}

impl KimiProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let credentials = read_credentials(&paths::kimi_credentials())?;
        if credentials.expires_at <= Utc::now() {
            return Err(ProviderError::NeedsAuth(
                "Kimi Code session expired — the CLI renews it as it runs".into(),
            ));
        }

        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .get(USAGES_URL)
            .bearer_auth(&credentials.access_token)
            .header("accept", "application/json")
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 | 403 => {
                return Err(ProviderError::NeedsAuth(
                    "Kimi Code rejected the session — run `kimi` and sign in again".into(),
                ));
            }
            404 => {
                return Err(ProviderError::Message(
                    "No Kimi Code plan on this account".into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Kimi Code rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "Kimi usage HTTP {status}: {body}"
                )));
            }
            _ => {}
        }

        let body: Value = response
            .json()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        parse_usage(&body)
    }
}

struct Credentials {
    access_token: String,
    expires_at: DateTime<Utc>,
}

/// `~/.kimi-code/credentials/kimi-code.json`. The token lives fifteen minutes
/// and the CLI renews it; minting one here would race the CLI for the file.
fn read_credentials(path: &std::path::Path) -> Result<Credentials, ProviderError> {
    let raw = std::fs::read_to_string(path).map_err(|_| {
        ProviderError::NeedsAuth("No Kimi Code session — run `kimi` and sign in".into())
    })?;
    let root: Value = serde_json::from_str(&raw).map_err(|e| ProviderError::Other(e.into()))?;

    let access_token = root
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ProviderError::NeedsAuth("Kimi Code token missing — run `kimi` and sign in".into())
        })?
        .to_string();

    let expires_at = root
        .get("expires_at")
        .and_then(Value::as_f64)
        .filter(|s| *s > 0.0)
        .and_then(|secs| DateTime::from_timestamp(secs.trunc() as i64, 0))
        .ok_or_else(|| {
            ProviderError::NeedsAuth("Kimi Code session has no expiry — sign in again".into())
        })?;

    Ok(Credentials {
        access_token,
        expires_at,
    })
}

fn parse_usage(body: &Value) -> Result<UsageReading, ProviderError> {
    let mut windows = Vec::new();

    if let Some(summary) = body.get("usage") {
        if let Some(window) = row("Weekly limit", summary) {
            windows.push(window);
        }
    }
    for entry in body
        .get("limits")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(label) = window_label(entry.get("window")) else {
            continue;
        };
        let Some(detail) = entry.get("detail") else {
            continue;
        };
        if let Some(window) = row(label, detail) {
            windows.push(window);
        }
    }

    if windows.is_empty() {
        return Err(ProviderError::Message(
            "No Kimi Code usage limits on this account".into(),
        ));
    }

    Ok(UsageReading {
        provider: ProviderId::Kimi,
        display_name: ProviderId::Kimi.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: None,
    })
}

/// One metered row. Counts arrive as decimal strings; when `used` is missing, a
/// valid limit and remaining pair still identifies the quota exactly.
fn row(label: &str, detail: &Value) -> Option<UsageWindow> {
    let limit = count(detail.get("limit"));
    let used = match count(detail.get("used")) {
        Some(used) => used,
        None => {
            let limit = limit?;
            let remaining = count(detail.get("remaining"))?;
            if limit <= 0.0 || !(0.0..=limit).contains(&remaining) {
                return None;
            }
            limit - remaining
        }
    };
    let used_pct = match limit {
        Some(limit) if limit > 0.0 => (used / limit * 100.0).clamp(0.0, 100.0),
        _ => 0.0,
    };
    Some(UsageWindow {
        label: label.into(),
        used_pct,
        resets_at: detail
            .get("resetTime")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339),
    })
}

/// A `limits[]` window: only the 5-hour rate window and the weekly quota are
/// named, so anything else is left out rather than mislabelled.
fn window_label(window: Option<&Value>) -> Option<&'static str> {
    let window = window?;
    let duration = count(window.get("duration"))?;
    match window.get("timeUnit").and_then(Value::as_str)? {
        "TIME_UNIT_MINUTE" if duration % 60.0 == 0.0 => (duration == 300.0).then_some("5h limit"),
        "TIME_UNIT_HOUR" if duration == 5.0 => Some("5h limit"),
        "TIME_UNIT_WEEK" if duration == 1.0 => Some("Weekly limit"),
        _ => None,
    }
}

fn count(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
}

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    const BODY: &str = r#"{
        "user": {"userId": "u_00000000000000000001", "membership": {"level": "LEVEL_ADVANCED"}},
        "usage": {"limit": "100", "used": "2", "remaining": "98",
                  "resetTime": "2026-09-15T19:39:34.389610Z"},
        "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
             "detail": {"limit": "100", "used": "8", "remaining": "92",
                        "resetTime": "2026-09-11T16:39:34.389610Z"}}
        ]
    }"#;

    #[test]
    fn reads_the_weekly_summary_and_the_five_hour_window() {
        let reading = parse_usage(&serde_json::from_str(BODY).unwrap()).unwrap();
        assert_eq!(reading.provider, ProviderId::Kimi);
        assert_eq!(reading.windows.len(), 2);
        assert_eq!(reading.windows[0].label, "Weekly limit");
        assert!((reading.windows[0].used_pct - 2.0).abs() < 0.001);
        assert_eq!(reading.windows[1].label, "5h limit");
        assert!((reading.windows[1].used_pct - 8.0).abs() < 0.001);
        assert!(reading.windows[0].resets_at.is_some());
    }

    #[test]
    fn derives_used_from_the_remaining_pair_and_skips_unknown_windows() {
        let body: Value = serde_json::from_str(
            r#"{"usage": {"limit": "40", "remaining": "10"},
                "limits": [{"window": {"duration": 90, "timeUnit": "TIME_UNIT_MINUTE"},
                            "detail": {"limit": "10", "used": "5"}}]}"#,
        )
        .unwrap();
        let reading = parse_usage(&body).unwrap();
        assert_eq!(reading.windows.len(), 1);
        assert!((reading.windows[0].used_pct - 75.0).abs() < 0.001);
        assert!(reading.windows[0].resets_at.is_none());
    }

    #[test]
    fn no_metered_rows_is_an_error_not_a_zero() {
        let body: Value = serde_json::from_str(r#"{"user": {}}"#).unwrap();
        assert!(parse_usage(&body).is_err());
    }
}
