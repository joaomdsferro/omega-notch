use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

/// Reads the plan usage Claude Desktop samples for itself.
///
/// The app appends its session and weekly percentages to
/// `plan-usage-history.json` every quarter of an hour while it is open. The
/// file carries no reset times, and goes quiet when the app is closed.
pub struct ClaudeDesktopProvider;

/// Two missed samples: the app is closed or asleep.
const STALE_AFTER_MINUTES: i64 = 30;

impl Provider for ClaudeDesktopProvider {
    fn id(&self) -> ProviderId {
        ProviderId::ClaudeDesktop
    }
}

impl ClaudeDesktopProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let desktop = paths::claude_desktop_dir();
        if !desktop.exists() {
            return Err(ProviderError::NeedsAuth(
                "Claude Desktop not found (~/.config/Claude)".into(),
            ));
        }

        // Prefer a side-channel snapshot if Claude Desktop (or a future helper)
        // wrote one next to our config.
        if let Some(reading) = read_side_channel_snapshot()? {
            return Ok(reading);
        }

        let path = paths::claude_desktop_usage_history();
        let raw = match std::fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(_) => {
                return Err(ProviderError::NeedsAuth(
                    "No Claude Desktop usage yet — open Claude Desktop and sign in".into(),
                ))
            }
        };
        reading_from_history(&raw, Utc::now()).ok_or_else(|| {
            ProviderError::NeedsAuth(
                "Claude Desktop has not recorded any usage yet — leave it open a while".into(),
            )
        })
    }
}

fn read_side_channel_snapshot() -> Result<Option<UsageReading>, ProviderError> {
    let path = paths::app_data_dir().join("claude-desktop-usage.json");
    if !path.exists() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(&path).map_err(|e| ProviderError::Other(e.into()))?;
    let value: Value = serde_json::from_str(&raw).map_err(|e| ProviderError::Other(e.into()))?;
    Ok(Some(reading_from_usage_json(&value, Fidelity::Derived)?))
}

/// The newest sample of `{"samples":[{"t":<ms>,"u":{"fh":<pct>,"sd":<pct>}}]}`.
fn reading_from_history(raw: &str, now: DateTime<Utc>) -> Option<UsageReading> {
    let value: Value = serde_json::from_str(raw).ok()?;
    let sample = value
        .get("samples")?
        .as_array()?
        .iter()
        .filter(|s| s.get("t").and_then(Value::as_i64).is_some())
        .max_by_key(|s| s.get("t").and_then(Value::as_i64))?;
    let sampled_at = Utc
        .timestamp_millis_opt(sample.get("t")?.as_i64()?)
        .single()?;

    let mut windows = Vec::new();
    for (key, label) in [("fh", "Current session"), ("sd", "Weekly limit")] {
        if let Some(pct) = sample.pointer(&format!("/u/{key}")).and_then(Value::as_f64) {
            windows.push(UsageWindow {
                label: label.into(),
                used_pct: pct.clamp(0.0, 100.0),
                resets_at: None,
            });
        }
    }
    if windows.is_empty() {
        return None;
    }

    let minutes = (now - sampled_at).num_minutes();
    let stale = minutes > STALE_AFTER_MINUTES;
    Some(UsageReading {
        provider: ProviderId::ClaudeDesktop,
        display_name: ProviderId::ClaudeDesktop.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: if stale {
            ReadingStatus::Stale
        } else {
            ReadingStatus::Ok
        },
        windows,
        fetched_at: sampled_at,
        message: stale.then(|| {
            let age = match minutes {
                m if m < 120 => format!("{m} minutes"),
                m if m < 48 * 60 => format!("{} hours", m / 60),
                m => format!("{} days", m / (24 * 60)),
            };
            format!("Claude Desktop last recorded its usage {age} ago — open it to refresh")
        }),
    })
}

fn reading_from_usage_json(value: &Value, fidelity: Fidelity) -> Result<UsageReading, ProviderError> {
    let mut windows = Vec::new();
    if let Some(obj) = value.get("five_hour") {
        if let Some(pct) = obj.get("utilization").and_then(|v| v.as_f64()) {
            let resets = obj
                .get("resets_at")
                .and_then(|v| v.as_str())
                .and_then(|s| {
                    chrono::DateTime::parse_from_rfc3339(s)
                        .ok()
                        .map(|d| d.with_timezone(&Utc))
                });
            windows.push(UsageWindow {
                label: "Current session".into(),
                used_pct: pct.clamp(0.0, 100.0),
                resets_at: resets,
            });
        }
    }
    if let Some(obj) = value.get("seven_day") {
        if let Some(pct) = obj.get("utilization").and_then(|v| v.as_f64()) {
            let resets = obj
                .get("resets_at")
                .and_then(|v| v.as_str())
                .and_then(|s| {
                    chrono::DateTime::parse_from_rfc3339(s)
                        .ok()
                        .map(|d| d.with_timezone(&Utc))
                });
            windows.push(UsageWindow {
                label: "Weekly limit".into(),
                used_pct: pct.clamp(0.0, 100.0),
                resets_at: resets,
            });
        }
    }

    if windows.is_empty() {
        return Err(ProviderError::Message(
            "Claude Desktop cache JSON had no usable windows".into(),
        ));
    }

    Ok(UsageReading {
        provider: ProviderId::ClaudeDesktop,
        display_name: ProviderId::ClaudeDesktop.display_name().to_string(),
        fidelity,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: Some("From Claude Desktop cache".into()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newest_history_sample_wins() {
        let raw = r#"{"version":2,"samples":[
            {"t":1790780461375,"org":"a","u":{"fh":36,"sd":9}},
            {"t":1790781360472,"org":"a","u":{"fh":48,"sd":10}}]}"#;
        let sampled = Utc.timestamp_millis_opt(1790781360472).single().unwrap();

        let fresh = reading_from_history(raw, sampled + chrono::Duration::minutes(5)).unwrap();
        assert_eq!(fresh.status, ReadingStatus::Ok);
        assert_eq!(fresh.fetched_at, sampled);
        assert_eq!(fresh.windows[0].used_pct, 48.0);
        assert_eq!(fresh.windows[1].used_pct, 10.0);
        assert!(fresh.message.is_none());

        let old = reading_from_history(raw, sampled + chrono::Duration::hours(3)).unwrap();
        assert_eq!(old.status, ReadingStatus::Stale);
        assert!(old.message.unwrap().contains("3 hours"));

        assert!(reading_from_history(r#"{"samples":[]}"#, sampled).is_none());
    }
}
