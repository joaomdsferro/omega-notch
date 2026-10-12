use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde::Deserialize;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

pub struct CursorProvider;

impl Provider for CursorProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Cursor
    }
}

impl CursorProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let token = read_access_token()?;
        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .get("https://api2.cursor.sh/auth/usage-summary")
            .bearer_auth(&token)
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        if response.status() == reqwest::StatusCode::UNAUTHORIZED
            || response.status() == reqwest::StatusCode::FORBIDDEN
        {
            return Err(ProviderError::NeedsAuth(
                "Cursor session expired — sign in again in Cursor".into(),
            ));
        }

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(ProviderError::Message(format!(
                "Cursor usage HTTP {status}: {body}"
            )));
        }

        let summary: UsageSummary = response
            .json()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        Ok(summary.into_reading())
    }
}

pub(super) fn read_access_token() -> Result<String, ProviderError> {
    let path = paths::cursor_state_db();
    if !path.exists() {
        return Err(ProviderError::NeedsAuth(
            "Cursor state database not found — is Cursor installed?".into(),
        ));
    }

    let uri = format!("file:{}?mode=ro", path.display());
    let conn = Connection::open_with_flags(
        &uri,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )
    .map_err(|e| ProviderError::Other(e.into()))?;

    let value: String = conn
        .query_row(
            "SELECT value FROM ItemTable WHERE key = ?1",
            ["cursorAuth/accessToken"],
            |row| row.get(0),
        )
        .map_err(|_| {
            ProviderError::NeedsAuth("No Cursor access token — sign in to Cursor".into())
        })?;

    let token = if value.starts_with('"') {
        serde_json::from_str::<String>(&value).unwrap_or(value)
    } else {
        value
    };

    if token.is_empty() {
        return Err(ProviderError::NeedsAuth(
            "Empty Cursor access token — sign in to Cursor".into(),
        ));
    }

    Ok(token)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageSummary {
    billing_cycle_end: Option<String>,
    is_unlimited: Option<bool>,
    individual_usage: Option<IndividualUsage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndividualUsage {
    plan: Option<PlanUsage>,
    on_demand: Option<OnDemandUsage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanUsage {
    enabled: Option<bool>,
    auto_percent_used: Option<f64>,
    api_percent_used: Option<f64>,
    total_percent_used: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OnDemandUsage {
    enabled: Option<bool>,
    used: Option<f64>,
    limit: Option<f64>,
}

impl UsageSummary {
    fn into_reading(self) -> UsageReading {
        let resets_at = self.billing_cycle_end.as_deref().and_then(parse_rfc3339);

        let mut windows = Vec::new();

        if self.is_unlimited == Some(true) {
            windows.push(UsageWindow {
                label: "Included usage".into(),
                used_pct: 0.0,
                resets_at,
            });
        } else if let Some(plan) = self.individual_usage.as_ref().and_then(|u| u.plan.as_ref()) {
            if plan.enabled.unwrap_or(true) {
                let total = plan.total_percent_used.unwrap_or(0.0).clamp(0.0, 100.0);
                windows.push(UsageWindow {
                    label: "Included usage".into(),
                    used_pct: total,
                    resets_at,
                });

                if let Some(api) = plan.api_percent_used {
                    windows.push(UsageWindow {
                        label: "API usage".into(),
                        used_pct: api.clamp(0.0, 100.0),
                        resets_at,
                    });
                }

                if let Some(auto) = plan.auto_percent_used {
                    if (auto - total).abs() > 0.5 {
                        windows.push(UsageWindow {
                            label: "Auto usage".into(),
                            used_pct: auto.clamp(0.0, 100.0),
                            resets_at,
                        });
                    }
                }
            }
        }

        if let Some(on_demand) = self
            .individual_usage
            .as_ref()
            .and_then(|u| u.on_demand.as_ref())
        {
            if on_demand.enabled.unwrap_or(false) {
                let pct = match (on_demand.used, on_demand.limit) {
                    (Some(used), Some(limit)) if limit > 0.0 => {
                        (used / limit * 100.0).clamp(0.0, 100.0)
                    }
                    _ => 0.0,
                };
                windows.push(UsageWindow {
                    label: "On-demand".into(),
                    used_pct: pct,
                    resets_at,
                });
            }
        }

        if windows.is_empty() {
            windows.push(UsageWindow {
                label: "Usage".into(),
                used_pct: 0.0,
                resets_at,
            });
        }

        UsageReading {
            provider: ProviderId::Cursor,
            display_name: ProviderId::Cursor.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Ok,
            windows,
            fetched_at: Utc::now(),
            message: None,
        }
    }
}

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}
