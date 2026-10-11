//! Signing in to GitHub Copilot from the notch, with GitHub's device flow.
//!
//! GitHub hands out a short code, the user confirms it in the browser, and the
//! OAuth token that comes back is kept in our own data dir. The client id is
//! the Copilot plugin's, the one every editor integration signs in with; a
//! token from any other app is refused by the Copilot quota endpoint.

use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::Value;

use crate::paths;

const CLIENT_ID: &str = "Iv1.b507a08c87ecfe98";
const DEVICE_CODE_URL: &str = "https://github.com/login/device/code";
const ACCESS_TOKEN_URL: &str = "https://github.com/login/oauth/access_token";

#[derive(Debug, Clone, Deserialize)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}

impl DeviceCode {
    pub fn expires_at(&self) -> DateTime<Utc> {
        Utc::now() + chrono::Duration::seconds(self.expires_in as i64)
    }
}

fn client() -> anyhow::Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .user_agent(crate::USER_AGENT)
        .timeout(Duration::from_secs(20))
        .build()?)
}

pub async fn request_device_code() -> anyhow::Result<DeviceCode> {
    let response = client()?
        .post(DEVICE_CODE_URL)
        .header("Accept", "application/json")
        .form(&[("client_id", CLIENT_ID), ("scope", "read:user")])
        .send()
        .await?
        .error_for_status()?;
    Ok(response.json().await?)
}

/// Waits until the user confirms the code in the browser, and returns the
/// OAuth token.
pub async fn wait_for_token(code: &DeviceCode) -> anyhow::Result<String> {
    let client = client()?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(code.expires_in);
    let mut interval = Duration::from_secs(code.interval.max(1));

    loop {
        tokio::time::sleep(interval).await;
        if tokio::time::Instant::now() >= deadline {
            anyhow::bail!("The code expired — try signing in again");
        }

        let body: Value = client
            .post(ACCESS_TOKEN_URL)
            .header("Accept", "application/json")
            .form(&[
                ("client_id", CLIENT_ID),
                ("device_code", code.device_code.as_str()),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            .send()
            .await?
            .json()
            .await?;

        if let Some(token) = body.get("access_token").and_then(Value::as_str) {
            return Ok(token.to_string());
        }
        match body.get("error").and_then(Value::as_str) {
            Some("authorization_pending") => {}
            Some("slow_down") => interval += Duration::from_secs(5),
            Some("expired_token") => anyhow::bail!("The code expired — try signing in again"),
            Some("access_denied") => anyhow::bail!("Sign-in was cancelled on GitHub"),
            Some(other) => anyhow::bail!(
                "GitHub refused the sign-in: {}",
                body.get("error_description")
                    .and_then(Value::as_str)
                    .unwrap_or(other)
            ),
            None => anyhow::bail!("Unexpected answer from GitHub"),
        }
    }
}

/// The token signed in from the notch, if any.
pub fn saved_token() -> Option<String> {
    let raw = std::fs::read_to_string(paths::copilot_token_file()).ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    value
        .get("oauth_token")
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// Keeps the token readable by the user only.
pub fn save_token(token: &str) -> anyhow::Result<()> {
    let path = paths::copilot_token_file();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?;
    file.write_all(serde_json::json!({ "oauth_token": token }).to_string().as_bytes())?;
    Ok(())
}
