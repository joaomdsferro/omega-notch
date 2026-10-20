use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

const BASE: &str = "https://api.kilo.ai";

pub struct KiloProvider;

impl Provider for KiloProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Kilo
    }
}

impl KiloProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let credentials = read_credentials(&paths::kilo_auth())?;

        let mut windows = Vec::new();
        let mut plan_name = None;

        // A coding plan's windows are the ring. An API key is refused here the
        // same way a plan-less account is; the balance below is what such an
        // account shows.
        if let Ok(body) = self
            .get_trpc(&credentials, "codingPlans.listSubscriptions", None)
            .await
        {
            for plan in subscriptions(&body) {
                let Some(id) = plan.get("id").and_then(Value::as_str) else {
                    continue;
                };
                let input = format!(r#"{{"subscriptionId":"{id}"}}"#);
                let Ok(usage) = self
                    .get_trpc(&credentials, "codingPlans.getUsage", Some(&input))
                    .await
                else {
                    continue;
                };
                let Ok(plan_windows) = usage_windows(&usage) else {
                    continue;
                };
                if plan_name.is_none() {
                    plan_name = plan
                        .get("planName")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    windows = plan_windows;
                }
            }
        }

        let mut message = None;
        if windows.is_empty() {
            let balance = self.get_rest(&credentials, "api/profile/balance").await?;
            let amount = balance.get("balance").and_then(Value::as_f64);
            windows.push(UsageWindow {
                label: "Credit balance".into(),
                used_pct: 0.0,
                resets_at: None,
            });
            if let Some(amount) = amount {
                message = Some(format!("${amount:.2} left"));
            }
        }

        Ok(UsageReading {
            provider: ProviderId::Kilo,
            display_name: ProviderId::Kilo.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Ok,
            windows,
            fetched_at: Utc::now(),
            message: message.or_else(|| plan_name.map(|name| format!("{name} plan"))),
        })
    }

    async fn get_trpc(
        &self,
        credentials: &Credentials,
        procedure: &str,
        input: Option<&str>,
    ) -> Result<Value, ProviderError> {
        let mut url = format!("{BASE}/api/trpc/{procedure}");
        if let Some(input) = input {
            url.push_str("?input=");
            url.push_str(&percent_encode(input));
        }
        let body = self.get(&url, credentials).await?;
        unwrap_trpc(body)
    }

    async fn get_rest(
        &self,
        credentials: &Credentials,
        path: &str,
    ) -> Result<Value, ProviderError> {
        self.get(&format!("{BASE}/{path}"), credentials).await
    }

    async fn get(&self, url: &str, credentials: &Credentials) -> Result<Value, ProviderError> {
        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let mut request = client
            .get(url)
            .bearer_auth(&credentials.token)
            .header("accept", "application/json");
        if let Some(org) = credentials.organization_id.as_deref() {
            request = request.header("x-kilocode-organizationid", org);
        }

        let response = request
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 | 403 => {
                return Err(ProviderError::NeedsAuth(
                    "Kilo rejected the session — run `kilo` and sign in again".into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Kilo rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "Kilo usage HTTP {status}: {body}"
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

struct Credentials {
    token: String,
    organization_id: Option<String>,
}

/// `~/.local/share/kilo/auth.json` holds one entry under `kilo`, either an API
/// key or the CLI's OAuth login. The file is re-read on every fetch: the CLI
/// refreshes the access token in place, so a cached copy would go stale.
fn read_credentials(path: &std::path::Path) -> Result<Credentials, ProviderError> {
    let raw = std::fs::read_to_string(path)
        .map_err(|_| ProviderError::NeedsAuth("No Kilo sign-in — run `kilo` and sign in".into()))?;
    let root: Value = serde_json::from_str(&raw).map_err(|e| ProviderError::Other(e.into()))?;
    let entry = root.get("kilo").ok_or_else(|| {
        ProviderError::NeedsAuth("Kilo's auth.json has no Kilo account — sign in again".into())
    })?;

    let token = match entry.get("type").and_then(Value::as_str) {
        Some("api") => entry.get("key"),
        Some("oauth") => entry.get("access"),
        _ => None,
    }
    .and_then(Value::as_str)
    .filter(|token| !token.is_empty())
    .ok_or_else(|| {
        ProviderError::NeedsAuth("Kilo's session has no access token — sign in again".into())
    })?;

    Ok(Credentials {
        token: token.to_string(),
        organization_id: entry
            .get("accountId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_string),
    })
}

/// tRPC answers `{"result":{"data":{"json":…}}}`; errors arrive with HTTP 200
/// as an `error` key, which must not be read as data.
fn unwrap_trpc(body: Value) -> Result<Value, ProviderError> {
    if body.get("error").is_some() {
        return Err(ProviderError::Message(
            "Kilo Cloud rejected the request".into(),
        ));
    }
    let data = body
        .pointer("/result/data")
        .ok_or_else(|| ProviderError::Message("Kilo returned no data".into()))?;
    Ok(data.get("json").cloned().unwrap_or_else(|| data.clone()))
}

fn subscriptions(body: &Value) -> Vec<&Value> {
    body.as_array()
        .map(|plans| {
            plans
                .iter()
                .filter(|plan| {
                    matches!(
                        plan.get("status").and_then(Value::as_str),
                        Some("active") | Some("past_due")
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

fn usage_windows(body: &Value) -> Result<Vec<UsageWindow>, ProviderError> {
    let entries = body
        .pointer("/subscription/windows")
        .and_then(Value::as_array)
        .ok_or_else(|| ProviderError::Message("Kilo returned no usage windows".into()))?;

    let mut windows: Vec<(Option<f64>, UsageWindow)> = entries
        .iter()
        .filter_map(|entry| {
            let remaining = entry.get("remainingPercent").and_then(Value::as_f64)?;
            let hours = period_hours(entry.get("period"));
            let label = label(hours);
            Some((
                hours,
                UsageWindow {
                    label,
                    used_pct: ((1.0 - remaining / 100.0) * 100.0).clamp(0.0, 100.0),
                    resets_at: entry.get("resetsAt").and_then(parse_date),
                },
            ))
        })
        .collect();

    if windows.is_empty() {
        return Err(ProviderError::Message(
            "Kilo returned no usage windows".into(),
        ));
    }
    windows.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    Ok(windows.into_iter().map(|(_, window)| window).collect())
}

fn period_hours(period: Option<&Value>) -> Option<f64> {
    let period = period?;
    let value = period
        .get("value")
        .and_then(Value::as_f64)
        .filter(|v| *v > 0.0)?;
    match period.get("unit").and_then(Value::as_str)? {
        "hour" => Some(value),
        "day" => Some(value * 24.0),
        "week" => Some(value * 7.0 * 24.0),
        "month" => Some(value * 30.0 * 24.0),
        _ => None,
    }
}

fn label(hours: Option<f64>) -> String {
    match hours {
        Some(hours) if (hours - 1.0).abs() < f64::EPSILON => "Hourly limit".into(),
        Some(hours) if (hours - 24.0).abs() < f64::EPSILON => "Daily limit".into(),
        Some(hours) if (hours - 168.0).abs() < f64::EPSILON => "Weekly limit".into(),
        Some(hours) if (hours - 720.0).abs() < f64::EPSILON => "Monthly limit".into(),
        Some(hours) if hours > 0.0 => format!("{}h limit", hours as i64),
        _ => "Plan limit".into(),
    }
}

fn parse_date(value: &Value) -> Option<DateTime<Utc>> {
    value
        .as_str()
        .and_then(|text| DateTime::parse_from_rfc3339(text).ok())
        .map(|dt| dt.with_timezone(&Utc))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwraps_the_trpc_envelope_and_its_errors() {
        let body: Value = serde_json::json!({"result": {"data": {"json": [{"id": "a"}]}}});
        assert!(unwrap_trpc(body).unwrap().is_array());
        assert!(unwrap_trpc(serde_json::json!({"error": {"message": "no"}})).is_err());
    }

    #[test]
    fn remaining_percent_is_inverted_and_windows_are_shortest_first() {
        let body: Value = serde_json::json!({"subscription": {"windows": [
            {"id": "month", "remainingPercent": 90.0,
             "resetsAt": "2026-11-01T00:00:00.000Z", "period": {"value": 1, "unit": "month"}},
            {"id": "five", "remainingPercent": 25.0, "period": {"value": 5, "unit": "hour"}}
        ]}});
        let windows = usage_windows(&body).unwrap();
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "5h limit");
        assert!((windows[0].used_pct - 75.0).abs() < 0.001);
        assert_eq!(windows[1].label, "Monthly limit");
        assert!((windows[1].used_pct - 10.0).abs() < 0.001);
        assert!(windows[1].resets_at.is_some());
    }

    #[test]
    fn only_metering_subscriptions_count() {
        let body: Value = serde_json::json!([
            {"id": "a", "status": "active"},
            {"id": "b", "status": "cancelled"},
            {"id": "c", "status": "past_due"}
        ]);
        let ids: Vec<&str> = subscriptions(&body)
            .iter()
            .filter_map(|plan| plan.get("id").and_then(Value::as_str))
            .collect();
        assert_eq!(ids, vec!["a", "c"]);
    }
}
