use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

/// Devin's seat management answers this; the Desktop app's cached quota can
/// lag behind the account, so each refresh asks instead of reading the cache.
const STATUS_URL: &str = "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus";

pub struct DevinProvider;

impl Provider for DevinProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Devin
    }
}

impl DevinProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let api_key = read_api_key(&paths::devin_desktop_db(), &paths::devin_cli_credentials())?;

        let payload = serde_json::json!({
            "metadata": {
                "apiKey": api_key,
                "ideName": "windsurf",
                "ideVersion": "1.108.2",
                "extensionName": "windsurf",
                "extensionVersion": "1.108.2",
                "locale": "en"
            }
        });

        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .post(STATUS_URL)
            .header("content-type", "application/json")
            .header("connect-protocol-version", "1")
            .json(&payload)
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 => {
                return Err(ProviderError::NeedsAuth(
                    "Devin rejected the session — sign in again in Devin".into(),
                ));
            }
            403 => {
                return Err(ProviderError::Message(
                    "Devin refused this session access to its usage".into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Devin rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "Devin usage HTTP {status}: {body}"
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

/// Devin Desktop's store first; the CLI's file is only reached when the
/// database has no sign-in, so a machine with both does not flip accounts
/// depending on which file was read.
fn read_api_key(desktop_db: &Path, cli_credentials: &Path) -> Result<String, ProviderError> {
    if let Some(key) = read_desktop_key(desktop_db) {
        return Ok(key);
    }
    read_cli_key(cli_credentials)
}

fn read_desktop_key(path: &Path) -> Option<String> {
    if !path.exists() {
        return None;
    }
    let uri = format!("file:{}?mode=ro", path.display());
    let conn = Connection::open_with_flags(
        &uri,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )
    .ok()?;
    let value: String = conn
        .query_row(
            "SELECT value FROM ItemTable WHERE key = ?1",
            ["windsurfAuthStatus"],
            |row| row.get(0),
        )
        .ok()?;
    let root: Value = serde_json::from_str(&value).ok()?;
    root.get("apiKey")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|key| !key.is_empty())
        .map(str::to_string)
}

/// The CLI's `credentials.toml`. Only `windsurf_api_key` is needed, so the
/// line is read directly rather than pulled in behind a TOML parser.
fn read_cli_key(path: &Path) -> Result<String, ProviderError> {
    let raw = std::fs::read_to_string(path).map_err(|_| {
        ProviderError::NeedsAuth("No Devin sign-in — run `devin auth login`".into())
    })?;
    for line in raw.lines() {
        let Some(rest) = line.strip_prefix("windsurf_api_key") else {
            continue;
        };
        if let Some(key) = rest.split('"').nth(1) {
            let key = key.trim();
            if !key.is_empty() {
                return Ok(key.to_string());
            }
        }
    }
    Err(ProviderError::NeedsAuth(
        "No Devin sign-in — run `devin auth login`".into(),
    ))
}

fn parse_usage(body: &Value) -> Result<UsageReading, ProviderError> {
    let plan = body
        .pointer("/userStatus/planStatus")
        .ok_or_else(|| ProviderError::Message("Devin usage response had no plan".into()))?;

    let mut windows = Vec::new();

    for (id, label, hidden) in [
        ("daily", "Daily quota", "hideDailyQuota"),
        ("weekly", "Weekly quota", "hideWeeklyQuota"),
    ] {
        if plan.get(hidden).and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let reset_key = format!("{id}QuotaResetAtUnix");
        let percent_key = format!("{id}QuotaRemainingPercent");
        let resets_at = number(plan.get(reset_key.as_str()))
            .filter(|secs| *secs > 0.0)
            .and_then(|secs| DateTime::from_timestamp(secs.trunc() as i64, 0));
        // The service drops the remaining percent at 0, leaving the reset
        // timestamp as the signal that the quota is still metered.
        let remaining = match number(plan.get(percent_key.as_str())) {
            Some(remaining) if (0.0..=100.0).contains(&remaining) => remaining,
            _ if resets_at.is_some() => 0.0,
            _ => continue,
        };
        windows.push(UsageWindow {
            label: label.into(),
            used_pct: (100.0 - remaining).clamp(0.0, 100.0),
            resets_at,
        });
    }

    if windows.is_empty() {
        return Err(ProviderError::Message(
            "Devin reported no quota on this account".into(),
        ));
    }

    Ok(UsageReading {
        provider: ProviderId::Devin,
        display_name: ProviderId::Devin.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: None,
    })
}

fn number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_daily_and_weekly_remaining_percent_as_used() {
        let body: Value = serde_json::from_str(
            r#"{"userStatus": {"planStatus": {"dailyQuotaRemainingPercent": 75.5,
                                              "dailyQuotaResetAtUnix": "1790000000",
                                              "weeklyQuotaRemainingPercent": 20,
                                              "weeklyQuotaResetAtUnix": 1795000000}}}"#,
        )
        .unwrap();
        let reading = parse_usage(&body).unwrap();
        assert_eq!(reading.windows.len(), 2);
        assert!((reading.windows[0].used_pct - 24.5).abs() < 0.001);
        assert!((reading.windows[1].used_pct - 80.0).abs() < 0.001);
        assert!(reading.windows[0].resets_at.is_some());
    }

    #[test]
    fn a_reset_without_a_percent_means_fully_used() {
        let body: Value = serde_json::from_str(
            r#"{"userStatus": {"planStatus": {"dailyQuotaResetAtUnix": "1790000000"}}}"#,
        )
        .unwrap();
        let reading = parse_usage(&body).unwrap();
        assert_eq!(reading.windows[0].used_pct, 100.0);
    }

    #[test]
    fn hidden_quotas_are_skipped() {
        let body: Value = serde_json::from_str(
            r#"{"userStatus": {"planStatus": {"hideDailyQuota": true,
                                              "dailyQuotaRemainingPercent": 50,
                                              "dailyQuotaResetAtUnix": "1790000000"}}}"#,
        )
        .unwrap();
        assert!(parse_usage(&body).is_err());
    }

    #[test]
    fn reads_the_cli_key_from_its_toml() {
        let dir = std::env::temp_dir().join(format!("omega-devin-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("credentials.toml");
        std::fs::write(
            &path,
            "windsurf_api_key = \"devin-dev-key-000000000000\"\nother = 1\n",
        )
        .unwrap();
        assert_eq!(read_cli_key(&path).unwrap(), "devin-dev-key-000000000000");
        std::fs::remove_dir_all(&dir).ok();
    }
}
