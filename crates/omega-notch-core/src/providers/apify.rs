use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

const LIMITS_URL: &str = "https://api.apify.com/v2/users/me/limits";

pub struct ApifyProvider;

impl Provider for ApifyProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Apify
    }
}

impl ApifyProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let token = read_token()?;

        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .get(LIMITS_URL)
            .bearer_auth(&token)
            .header("accept", "application/json")
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 => {
                return Err(ProviderError::NeedsAuth(
                    "Apify rejected the token — run `apify login` again".into(),
                ));
            }
            403 => {
                return Err(ProviderError::Message(
                    "This Apify token cannot read account limits — use one with full account access"
                        .into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Apify rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "Apify usage HTTP {status}: {body}"
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

/// `APIFY_TOKEN` first, then the login `apify login` files. The CLI's keyring
/// is not consulted: reading another app's keychain item can prompt, and a
/// token that is not there yet should read as a sign-out, not a dialogue.
fn read_token() -> Result<String, ProviderError> {
    if let Some(token) = std::env::var("APIFY_TOKEN").ok().filter(|s| !s.is_empty()) {
        return Ok(token);
    }

    let raw = std::fs::read_to_string(paths::apify_auth()).map_err(|_| {
        ProviderError::NeedsAuth("No Apify sign-in — run `apify login` or set APIFY_TOKEN".into())
    })?;
    let root: Value = serde_json::from_str(&raw).map_err(|_| {
        ProviderError::Message("~/.apify/auth.json is not readable — run apify login again".into())
    })?;

    root.get("token")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            ProviderError::NeedsAuth(
                "~/.apify/auth.json has no token — run `apify login` again".into(),
            )
        })
}

fn parse_usage(body: &Value) -> Result<UsageReading, ProviderError> {
    let data = body
        .get("data")
        .ok_or_else(|| ProviderError::Message("Apify usage response had no data".into()))?;

    let used = data
        .pointer("/current/monthlyUsageUsd")
        .and_then(Value::as_f64)
        .filter(|used| used.is_finite() && *used >= 0.0)
        .ok_or_else(|| {
            ProviderError::Message("Apify usage response had no monthly spend".into())
        })?;

    let cap = data
        .pointer("/limits/maxMonthlyUsageUsd")
        .and_then(Value::as_f64)
        .filter(|cap| cap.is_finite() && *cap > 0.0);

    let resets_at = data
        .pointer("/monthlyUsageCycle/endAt")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339);

    let used_pct = cap.map(|cap| used / cap * 100.0).unwrap_or(0.0);

    Ok(UsageReading {
        provider: ProviderId::Apify,
        display_name: ProviderId::Apify.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows: vec![UsageWindow {
            label: "Monthly usage".into(),
            used_pct,
            resets_at,
        }],
        fetched_at: Utc::now(),
        message: None,
    })
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
    fn reads_this_cycles_spend_against_the_account_cap() {
        let body: Value = serde_json::from_str(
            r#"{"data": {"monthlyUsageCycle": {"startAt": "2026-09-02T00:00:00.000Z",
                                               "endAt": "2026-10-01T23:59:59.999Z"},
                         "limits": {"maxMonthlyUsageUsd": 1500},
                         "current": {"monthlyUsageUsd": 1200.6}}}"#,
        )
        .unwrap();
        let reading = parse_usage(&body).unwrap();
        assert!((reading.windows[0].used_pct - 80.04).abs() < 0.01);
        assert!(reading.windows[0].resets_at.is_some());
    }

    #[test]
    fn a_missing_cap_is_a_count_not_a_zero_ring() {
        let body: Value =
            serde_json::from_str(r#"{"data": {"current": {"monthlyUsageUsd": 12.5}}}"#).unwrap();
        let reading = parse_usage(&body).unwrap();
        assert_eq!(reading.windows[0].used_pct, 0.0);
        assert!(reading.windows[0].resets_at.is_none());
    }

    #[test]
    fn an_invalid_spend_is_an_error() {
        let body: Value = serde_json::from_str(r#"{"data": {"current": {}}}"#).unwrap();
        assert!(parse_usage(&body).is_err());
    }
}
