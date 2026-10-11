use chrono::{DateTime, Utc};
use serde::Deserialize;

use super::cursor::read_access_token;
use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

/// Weekly included usage for Grok Bot (x.ai/bot).
///
/// Grok Bot runs on Cursor's backend: the app's Usage & Billing card comes from
/// `aiserver.v1.DashboardService/GetSandUsageStatus`. Grok Bot keeps its own
/// token in the OS keyring, so the call is made with the Cursor sign-in from
/// `state.vscdb` and works when both apps use the same account.
pub struct GrokBotProvider;

const USAGE_URL: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus";

impl Provider for GrokBotProvider {
    fn id(&self) -> ProviderId {
        ProviderId::GrokBot
    }
}

impl GrokBotProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        if !paths::grok_bot_dir().exists() {
            return Err(ProviderError::NeedsAuth(
                "Grok Bot not found (~/.grokbot)".into(),
            ));
        }

        let token = read_access_token().map_err(|_| {
            ProviderError::NeedsAuth(
                "Sign in to Cursor with your Grok Bot account to track its usage".into(),
            )
        })?;
        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        // Connect protocol, unary call with a JSON body.
        let response = client
            .post(USAGE_URL)
            .bearer_auth(&token)
            .header("Connect-Protocol-Version", "1")
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body("{}")
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
                "Grok Bot usage HTTP {status}: {body}"
            )));
        }

        let status: SandUsageStatus = response
            .json()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        Ok(status.into_reading())
    }
}

/// `GetSandUsageStatusResponse`; proto3 JSON leaves out fields at their default.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SandUsageStatus {
    usage_percent: Option<f64>,
    next_reset_timestamp_utc: Option<String>,
    #[serde(default)]
    has_non_zero_included_limit: bool,
    #[serde(default)]
    uses_pooled_enterprise_allowance: bool,
    grok_plan_label: Option<String>,
}

impl SandUsageStatus {
    fn into_reading(self) -> UsageReading {
        let resets_at = self
            .next_reset_timestamp_utc
            .as_deref()
            .and_then(parse_rfc3339);

        let label = if self.uses_pooled_enterprise_allowance {
            "Team allowance".to_string()
        } else {
            "Weekly".to_string()
        };

        let used_pct = self.usage_percent.unwrap_or(0.0).clamp(0.0, 100.0);

        let message = if self.has_non_zero_included_limit {
            self.grok_plan_label
                .filter(|l| !l.trim().is_empty())
                .map(|l| l.trim().to_string())
        } else {
            Some("No included usage on this plan".to_string())
        };

        UsageReading {
            provider: ProviderId::GrokBot,
            display_name: ProviderId::GrokBot.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Ok,
            windows: vec![UsageWindow {
                label,
                used_pct,
                resets_at,
            }],
            fetched_at: Utc::now(),
            message,
        }
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

    #[test]
    fn reads_weekly_percent_and_reset() {
        let raw = r#"{"currentPeriodStart":"2026-09-30T00:00:00Z","nextResetTimestampUtc":"2026-10-07T00:00:00Z","usagePercent":1.4,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true}"#;
        let reading = serde_json::from_str::<SandUsageStatus>(raw).unwrap().into_reading();
        assert_eq!(reading.windows.len(), 1);
        assert_eq!(reading.windows[0].label, "Weekly");
        assert!((reading.windows[0].used_pct - 1.4).abs() < 1e-9);
        assert_eq!(
            reading.windows[0].resets_at.unwrap().to_rfc3339(),
            "2026-10-07T00:00:00+00:00"
        );
    }

    #[test]
    fn omitted_percent_with_a_limit_is_zero() {
        let raw = r#"{"hasNonZeroIncludedLimit":true}"#;
        let reading = serde_json::from_str::<SandUsageStatus>(raw).unwrap().into_reading();
        assert_eq!(reading.windows[0].used_pct, 0.0);
    }
}
