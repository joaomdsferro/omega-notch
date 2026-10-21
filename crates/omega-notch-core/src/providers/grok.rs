use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

const CREDITS_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const TRUSTED_ISSUER: &str = "https://auth.x.ai";
const TOKEN_URL: &str = "https://auth.x.ai/oauth2/token";

pub struct GrokProvider;

impl Provider for GrokProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Grok
    }
}

/// The access token minted here, with the refresh token it came from: a fresh
/// `grok login` writes a new refresh token, and a token renewed from the old
/// one must not outlive that. The file itself is never written.
struct Renewed {
    access_token: String,
    expires_at: DateTime<Utc>,
    from: String,
}

static RENEWED: Mutex<Option<Renewed>> = Mutex::new(None);

impl GrokProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let credentials = read_credentials(&paths::grok_auth())?;
        let token = self.live_token(&credentials).await?;

        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .get(CREDITS_URL)
            .bearer_auth(&token)
            .header("x-xai-token-auth", "xai-grok-cli")
            .header("accept", "application/json")
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 | 403 => {
                *RENEWED.lock().unwrap() = None;
                return Err(ProviderError::NeedsAuth(
                    "Grok session expired — run `grok login`".into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Grok rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "Grok usage HTTP {status}: {body}"
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

    /// The file's own token while it lives — the CLI renewed it, so ours is
    /// stale by definition — then the one minted here, then a new one.
    async fn live_token(&self, credentials: &Credentials) -> Result<String, ProviderError> {
        if credentials.expires_at > Utc::now() {
            *RENEWED.lock().unwrap() = None;
            return Ok(credentials.access_token.clone());
        }

        {
            let renewed = RENEWED.lock().unwrap();
            if let Some(renewed) = renewed.as_ref() {
                let same_session = Some(&renewed.from) == credentials.refresh_token.as_ref();
                if same_session && renewed.expires_at > Utc::now() {
                    return Ok(renewed.access_token.clone());
                }
            }
        }

        let (refresh_token, client_id) = credentials
            .refresh_token
            .as_ref()
            .zip(credentials.client_id.as_ref())
            .ok_or_else(|| {
                ProviderError::NeedsAuth(
                    "Grok session expired — run `grok login` to renew it".into(),
                )
            })?;

        let (access_token, expires_at) = self.renew(refresh_token, client_id).await?;
        *RENEWED.lock().unwrap() = Some(Renewed {
            access_token: access_token.clone(),
            expires_at,
            from: refresh_token.clone(),
        });
        Ok(access_token)
    }

    /// The `refresh_token` grant against the issuer's token endpoint. The
    /// issuer issues a new refresh token on every renewal but does not revoke
    /// the old one, so the CLI's copy in the file keeps working.
    async fn renew(
        &self,
        refresh_token: &str,
        client_id: &str,
    ) -> Result<(String, DateTime<Utc>), ProviderError> {
        let expired = || {
            ProviderError::NeedsAuth("Grok session expired — run `grok login` to renew it".into())
        };

        let form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", client_id),
        ]
        .iter()
        .map(|(key, value)| format!("{key}={}", percent_encode(value)))
        .collect::<Vec<_>>()
        .join("&");

        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .post(TOKEN_URL)
            .header("content-type", "application/x-www-form-urlencoded")
            .header("accept", "application/json")
            .body(form)
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        if !response.status().is_success() {
            return Err(expired());
        }

        let body: Value = response.json().await.map_err(|_| expired())?;
        let access_token = body
            .get("access_token")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(expired)?
            .to_string();
        // `auth.x.ai` says six hours; an issuer that does not say gets an hour,
        // sooner than any lifetime seen, rather than a token trusted past it.
        let lifetime = body
            .get("expires_in")
            .and_then(Value::as_f64)
            .unwrap_or(3600.0);
        let expires_at = Utc::now() + chrono::Duration::milliseconds((lifetime * 1000.0) as i64);
        Ok((access_token, expires_at))
    }
}

struct Credentials {
    access_token: String,
    expires_at: DateTime<Utc>,
    refresh_token: Option<String>,
    client_id: Option<String>,
}

fn read_credentials(path: &std::path::Path) -> Result<Credentials, ProviderError> {
    let raw = std::fs::read_to_string(path)
        .map_err(|_| ProviderError::NeedsAuth("No Grok sign-in — run `grok login`".into()))?;
    let root: Value = serde_json::from_str(&raw).map_err(|e| ProviderError::Other(e.into()))?;

    let pick = pick_entry(&root).ok_or_else(|| {
        ProviderError::NeedsAuth("No Grok sign-in for auth.x.ai — run `grok login`".into())
    })?;

    let access_token = pick
        .get("key")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ProviderError::NeedsAuth("Grok session has no access token".into()))?
        .to_string();

    Ok(Credentials {
        access_token,
        expires_at: pick
            .get("expires_at")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339)
            .unwrap_or_else(|| Utc::now() + chrono::Duration::days(30)),
        refresh_token: non_empty(pick.get("refresh_token")),
        client_id: non_empty(pick.get("oidc_client_id")),
    })
}

/// The file is keyed by `issuer::client_id`. Only a session minted by xAI
/// itself counts: a customer IdP's token is meant for a private proxy, and
/// sending it to the public endpoint would hand someone else's credential
/// away. One live trusted session wins; otherwise the first trusted one.
fn pick_entry(root: &Value) -> Option<&Value> {
    let entries: Vec<&Value> = root
        .as_object()?
        .iter()
        .filter(|(key, value)| {
            key.split("::").next() == Some(TRUSTED_ISSUER)
                || value.get("oidc_issuer").and_then(Value::as_str) == Some(TRUSTED_ISSUER)
        })
        .map(|(_, value)| value)
        .collect();

    entries
        .iter()
        .find(|entry| {
            entry
                .get("expires_at")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339)
                .is_none_or(|expiry| expiry > Utc::now())
        })
        .or_else(|| entries.first())
        .copied()
}

fn parse_usage(body: &Value) -> Result<UsageReading, ProviderError> {
    let config = body
        .get("config")
        .ok_or_else(|| ProviderError::Message("Grok usage response had no config".into()))?;

    let period_end = config
        .pointer("/currentPeriod/end")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339)
        .or_else(|| {
            config
                .get("billingPeriodEnd")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339)
        });

    let mut windows = Vec::new();

    if let Some(pct) = config.get("creditUsagePercent").and_then(Value::as_f64) {
        windows.push(UsageWindow {
            label: product_label(config).unwrap_or_else(|| "Grok Build".into()),
            used_pct: pct.clamp(0.0, 100.0),
            resets_at: period_end,
        });
    } else if let Some(products) = config.get("productUsage").and_then(Value::as_array) {
        for product in products {
            let Some(pct) = product.get("usagePercent").and_then(Value::as_f64) else {
                continue;
            };
            let name = product.get("product").and_then(Value::as_str).map(humanize);
            windows.push(UsageWindow {
                label: name.unwrap_or_else(|| "Usage".into()),
                used_pct: pct.clamp(0.0, 100.0),
                resets_at: period_end,
            });
        }
    }

    // A weekly plan pool states its window and omits the usage keys until
    // usage lands; Grok's own `/usage` still shows it as a 0% weekly bar.
    if windows.is_empty()
        && config
            .pointer("/currentPeriod/type")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind.contains("WEEKLY"))
    {
        windows.push(UsageWindow {
            label: "Weekly limit".into(),
            used_pct: 0.0,
            resets_at: period_end,
        });
    }

    if windows.is_empty() {
        return Err(ProviderError::Message(
            "Grok has nothing metered on this account yet".into(),
        ));
    }

    Ok(UsageReading {
        provider: ProviderId::Grok,
        display_name: ProviderId::Grok.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: None,
    })
}

fn product_label(config: &Value) -> Option<String> {
    config
        .get("productUsage")
        .and_then(Value::as_array)
        .and_then(|products| products.first())
        .and_then(|product| product.get("product"))
        .and_then(Value::as_str)
        .map(humanize)
}

/// "GrokBuild" → "Grok Build".
fn humanize(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 2);
    for ch in name.chars() {
        if ch.is_uppercase() && !out.is_empty() {
            out.push(' ');
        }
        out.push(ch);
    }
    out
}

fn non_empty(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
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

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_a_live_trusted_session_over_a_stale_or_foreign_one() {
        let root: Value = serde_json::from_str(
            r#"{
                "https://evil.example::client-1": {"key": "foreign", "expires_at": "2999-01-01T00:00:00Z"},
                "https://auth.x.ai::client-a": {"key": "stale", "expires_at": "2000-01-01T00:00:00Z"},
                "https://auth.x.ai::client-b": {"key": "live", "expires_at": "2999-01-01T00:00:00Z"}
            }"#,
        )
        .unwrap();
        assert_eq!(pick_entry(&root).unwrap()["key"], "live");
    }

    #[test]
    fn issuer_is_compared_whole_not_by_prefix() {
        let root: Value = serde_json::from_str(
            r#"{"https://auth.x.ai.example.com::c": {"key": "no", "expires_at": "2999-01-01T00:00:00Z"}}"#,
        )
        .unwrap();
        assert!(pick_entry(&root).is_none());
    }

    #[test]
    fn reads_the_credits_percentage() {
        let body: Value = serde_json::from_str(
            r#"{"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                                             "start": "2026-09-05T08:21:18.802818+00:00",
                                             "end": "2026-09-12T08:21:18.802818+00:00"},
                           "creditUsagePercent": 8.0,
                           "productUsage": [{"product": "GrokBuild", "usagePercent": 8.0}]}}"#,
        )
        .unwrap();
        let reading = parse_usage(&body).unwrap();
        assert_eq!(reading.windows.len(), 1);
        assert_eq!(reading.windows[0].label, "Grok Build");
        assert!((reading.windows[0].used_pct - 8.0).abs() < 0.001);
        assert!(reading.windows[0].resets_at.is_some());
    }

    #[test]
    fn a_fresh_weekly_period_is_a_zero_bar_not_an_error() {
        let body: Value = serde_json::from_str(
            r#"{"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-09-12T08:21:18.802818+00:00"}}}"#,
        )
        .unwrap();
        let reading = parse_usage(&body).unwrap();
        assert_eq!(reading.windows[0].label, "Weekly limit");
        assert_eq!(reading.windows[0].used_pct, 0.0);
    }
}
