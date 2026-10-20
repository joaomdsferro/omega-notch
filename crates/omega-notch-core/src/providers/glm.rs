use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

pub struct GlmProvider;

impl Provider for GlmProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Glm
    }
}

struct Credentials {
    token: String,
    base_url: String,
}

impl GlmProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let credentials = load_credentials(&paths::claude_settings(), &paths::opencode_auth())?;

        let url = format!("{}/api/monitor/usage/quota/limit", credentials.base_url);
        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .get(&url)
            .header("authorization", &credentials.token)
            .header("content-type", "application/json")
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 | 403 => {
                return Err(ProviderError::NeedsAuth(
                    "Z.ai rejected the GLM key — sign in again in the coding tool that holds it"
                        .into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Z.ai rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "GLM usage HTTP {status}: {body}"
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

/// GLM has no tool of its own to find: it is here when a coding tool holds
/// its key.
pub(super) fn detected() -> bool {
    load_credentials(&paths::claude_settings(), &paths::opencode_auth()).is_ok()
}

/// The GLM key is never held by this app: it rides on a coding tool that the
/// user already set up. `~/.claude/settings.json` first, then opencode's
/// sign-in. ZCode's encrypted store is not read here.
fn load_credentials(
    claude_settings: &Path,
    opencode_auth: &Path,
) -> Result<Credentials, ProviderError> {
    if let Some(credentials) = from_claude_settings(claude_settings) {
        return Ok(credentials);
    }
    if let Some(credentials) = from_opencode(opencode_auth) {
        return Ok(credentials);
    }
    Err(ProviderError::NeedsAuth(
        "No GLM Coding Plan key — set one up in Claude Code or opencode".into(),
    ))
}

fn from_claude_settings(path: &Path) -> Option<Credentials> {
    let root: Value = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    let env = root.get("env")?;
    let token = env
        .get("ANTHROPIC_AUTH_TOKEN")
        .or_else(|| env.get("ANTHROPIC_API_KEY"))
        .and_then(Value::as_str)
        .filter(|token| !token.is_empty())?;
    let host = url_host(env.get("ANTHROPIC_BASE_URL").and_then(Value::as_str)?)?;
    // Without a Z.ai base URL the token belongs to whichever provider it
    // names, not to GLM.
    let base_url = zai_console(&host)?;
    Some(Credentials {
        token: token.to_string(),
        base_url,
    })
}

fn from_opencode(path: &Path) -> Option<Credentials> {
    let root: Value = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    for id in [
        "zai-coding-plan",
        "zai",
        "z-ai",
        "z.ai",
        "glm",
        "zhipu",
        "zhipuai",
    ] {
        let Some(entry) = root.get(id) else {
            continue;
        };
        let token = entry
            .as_str()
            .or_else(|| {
                [
                    "apiKey",
                    "api_key",
                    "token",
                    "key",
                    "accessToken",
                    "auth_token",
                ]
                .iter()
                .find_map(|key| entry.get(*key).and_then(Value::as_str))
            })
            .filter(|token| !token.is_empty())?;
        let base_url = if id.starts_with("zhipu") {
            "https://open.bigmodel.cn".to_string()
        } else {
            "https://api.z.ai".to_string()
        };
        return Some(Credentials {
            token: token.to_string(),
            base_url,
        });
    }
    None
}

fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let host = rest.split('/').next()?.split(':').next()?;
    (!host.is_empty()).then(|| host.to_string())
}

fn zai_console(host: &str) -> Option<String> {
    if host == "api.z.ai" || host.ends_with(".z.ai") {
        Some("https://api.z.ai".into())
    } else if host == "open.bigmodel.cn" || host.ends_with(".bigmodel.cn") {
        Some("https://open.bigmodel.cn".into())
    } else {
        None
    }
}

fn parse_usage(body: &Value) -> Result<UsageReading, ProviderError> {
    let code = body.get("code").and_then(Value::as_i64);
    let success = body
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !success && code.is_some_and(|code| code != 200) {
        return Err(match code {
            Some(401) | Some(403) => ProviderError::NeedsAuth("Z.ai rejected the GLM key".into()),
            Some(429) => ProviderError::Message("Z.ai rate-limited the usage request".into()),
            _ => ProviderError::Message(format!(
                "GLM usage failed: {}",
                body.get("msg").unwrap_or(&Value::Null)
            )),
        });
    }

    let limits = body
        .pointer("/data/limits")
        .and_then(Value::as_array)
        .ok_or_else(|| ProviderError::Message("GLM usage response had no limits".into()))?;

    let mut windows: Vec<(u8, UsageWindow)> = limits
        .iter()
        .filter_map(|limit| {
            let percentage = limit.get("percentage").and_then(Value::as_f64)?;
            let (rank, label) = window_label(limit);
            Some((
                rank,
                UsageWindow {
                    label,
                    used_pct: percentage.clamp(0.0, 100.0),
                    resets_at: limit
                        .get("nextResetTime")
                        .and_then(Value::as_f64)
                        .filter(|ms| *ms > 0.0)
                        .and_then(|ms| DateTime::from_timestamp((ms / 1000.0) as i64, 0)),
                },
            ))
        })
        .collect();

    if windows.is_empty() {
        return Err(ProviderError::Message(
            "Z.ai reported no GLM usage limits".into(),
        ));
    }
    windows.sort_by_key(|(rank, _)| *rank);

    Ok(UsageReading {
        provider: ProviderId::Glm,
        display_name: ProviderId::Glm.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows: windows.into_iter().map(|(_, window)| window).collect(),
        fetched_at: Utc::now(),
        message: body
            .pointer("/data/level")
            .and_then(Value::as_str)
            .map(|level| format!("{level} plan")),
    })
}

/// (sort rank, label). (hours, 5) is the rolling session and (weeks, 1) the
/// weekly allowance; `TIME_LIMIT` is the monthly MCP budget.
fn window_label(limit: &Value) -> (u8, String) {
    if limit.get("type").and_then(Value::as_str) == Some("TIME_LIMIT") {
        return (2, "MCP (1 month)".into());
    }
    match (
        limit.get("unit").and_then(Value::as_i64),
        limit.get("number").and_then(Value::as_i64),
    ) {
        (Some(3), Some(5)) => (0, "Current session".into()),
        (Some(6), Some(1)) => (1, "Weekly".into()),
        (Some(3), Some(hours)) => (3, format!("Usage ({hours} h)")),
        (Some(6), Some(weeks)) => (3, format!("Usage ({weeks} wk)")),
        _ => (3, "Usage".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_session_weekly_and_mcp_windows_in_order() {
        let body = serde_json::json!({
            "success": true,
            "data": {"level": "pro", "limits": [
                {"type": "TIME_LIMIT", "percentage": 4.0},
                {"type": "TOKENS_LIMIT", "unit": 6, "number": 1,
                 "percentage": 8.1, "nextResetTime": 1789190400000.0},
                {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12.5}
            ]}
        });
        let reading = parse_usage(&body).unwrap();
        let labels: Vec<&str> = reading.windows.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(labels, ["Current session", "Weekly", "MCP (1 month)"]);
        assert!((reading.windows[0].used_pct - 12.5).abs() < 0.001);
        assert!(reading.windows[1].resets_at.is_some());
    }

    #[test]
    fn a_key_for_another_provider_is_not_claimed() {
        let dir = std::env::temp_dir().join(format!("omega-glm-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let settings = dir.join("settings.json");
        std::fs::write(
            &settings,
            r#"{"env":{"ANTHROPIC_AUTH_TOKEN":"k","ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}"#,
        )
        .unwrap();
        assert!(from_claude_settings(&settings).is_none());

        std::fs::write(
            &settings,
            r#"{"env":{"ANTHROPIC_AUTH_TOKEN":"k","ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}"#,
        )
        .unwrap();
        let credentials = from_claude_settings(&settings).unwrap();
        assert_eq!(credentials.base_url, "https://api.z.ai");
        std::fs::remove_dir_all(&dir).ok();
    }
}
