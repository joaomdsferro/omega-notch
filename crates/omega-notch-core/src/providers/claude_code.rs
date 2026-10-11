use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

pub struct ClaudeCodeProvider;

impl Provider for ClaudeCodeProvider {
    fn id(&self) -> ProviderId {
        ProviderId::ClaudeCode
    }
}

/// The usage endpoint shares its rate limit with Claude Code itself, so it is
/// asked no more often than this; in between, the last reading is reused.
/// Kept at 60s so busy polls (~30s) stay fresh without doubling every tick.
const MIN_INTERVAL: Duration = Duration::from_secs(60);
/// First pause after a 429 that names no `Retry-After`; doubles up to the cap.
/// Starts above `MIN_INTERVAL` so a hit does not immediately resume fast polling.
const BACKOFF_START: Duration = Duration::from_secs(120);
const BACKOFF_MAX: Duration = Duration::from_secs(1800);
/// How long a reading can stand in for a refused request before saying so.
const QUIET_FOR: Duration = Duration::from_secs(900);

const RATE_LIMITED: &str = "Claude usage rate-limited — try again shortly";

struct Throttle {
    last_ok: Option<(Instant, UsageReading)>,
    blocked_until: Option<Instant>,
    backoff: Option<Duration>,
}

static THROTTLE: Mutex<Throttle> = Mutex::new(Throttle {
    last_ok: None,
    blocked_until: None,
    backoff: None,
});

enum Failure {
    RateLimited(Option<Duration>),
    Other(ProviderError),
}

impl Throttle {
    /// The last reading, if it is recent enough to answer in place of a request.
    fn reusable(&self, max_age: Duration) -> Option<UsageReading> {
        let (at, reading) = self.last_ok.as_ref()?;
        let now = Utc::now();
        // A window that has rolled over since makes the numbers wrong.
        let rolled_over = reading
            .windows
            .iter()
            .any(|w| w.resets_at.is_some_and(|t| t <= now));
        (at.elapsed() < max_age && !rolled_over).then(|| reading.clone())
    }

    fn rate_limited(&self) -> Result<UsageReading, ProviderError> {
        self.reusable(QUIET_FOR)
            .ok_or_else(|| ProviderError::Message(RATE_LIMITED.into()))
    }
}

impl ClaudeCodeProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        {
            let throttle = THROTTLE.lock().unwrap();
            if let Some(reading) = throttle.reusable(MIN_INTERVAL) {
                return Ok(reading);
            }
            if throttle.blocked_until.is_some_and(|t| Instant::now() < t) {
                return throttle.rate_limited();
            }
        }

        let result = self.fetch_remote().await;

        let mut throttle = THROTTLE.lock().unwrap();
        match result {
            Ok(reading) => {
                throttle.last_ok = Some((Instant::now(), reading.clone()));
                throttle.blocked_until = None;
                throttle.backoff = None;
                Ok(reading)
            }
            Err(Failure::RateLimited(retry_after)) => {
                let doubled = throttle
                    .backoff
                    .map_or(BACKOFF_START, |b| (b * 2).min(BACKOFF_MAX));
                throttle.backoff = Some(doubled);
                let pause = retry_after.map_or(doubled, |r| r.clamp(MIN_INTERVAL, BACKOFF_MAX));
                throttle.blocked_until = Some(Instant::now() + pause);
                throttle.rate_limited()
            }
            Err(Failure::Other(err)) => Err(err),
        }
    }

    async fn fetch_remote(&self) -> Result<UsageReading, Failure> {
        let token = read_oauth_token().map_err(Failure::Other)?;
        let other = |e: reqwest::Error| Failure::Other(ProviderError::Other(e.into()));
        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(20))
            .build()
            .map_err(other)?;

        let response = client
            .get("https://api.anthropic.com/api/oauth/usage")
            .bearer_auth(&token)
            .header("anthropic-beta", "oauth-2025-04-20")
            .send()
            .await
            .map_err(other)?;

        if response.status() == reqwest::StatusCode::UNAUTHORIZED
            || response.status() == reqwest::StatusCode::FORBIDDEN
        {
            return Err(Failure::Other(ProviderError::NeedsAuth(
                "Claude Code OAuth expired — run `claude` and sign in again".into(),
            )));
        }

        if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let retry_after = response
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<u64>().ok())
                .map(Duration::from_secs);
            return Err(Failure::RateLimited(retry_after));
        }

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(Failure::Other(ProviderError::Message(format!(
                "Claude usage HTTP {status}: {body}"
            ))));
        }

        let body: Value = response.json().await.map_err(other)?;

        Ok(parse_usage(body))
    }
}

fn read_oauth_token() -> Result<String, ProviderError> {
    let path = paths::claude_credentials();
    if !path.exists() {
        return Err(ProviderError::NeedsAuth(
            "No ~/.claude/.credentials.json — sign in with Claude Code".into(),
        ));
    }

    let raw = std::fs::read_to_string(&path).map_err(|e| ProviderError::Other(e.into()))?;
    let value: Value = serde_json::from_str(&raw).map_err(|e| ProviderError::Other(e.into()))?;
    let token = value
        .pointer("/claudeAiOauth/accessToken")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ProviderError::NeedsAuth("Claude OAuth token missing — sign in with Claude Code".into())
        })?;

    Ok(token.to_string())
}

fn parse_usage(body: Value) -> UsageReading {
    let mut windows = Vec::new();

    if let Some(obj) = body.get("five_hour") {
        if let Some(w) = window_from_bucket("Current session", obj) {
            windows.push(w);
        }
    }
    if let Some(obj) = body.get("seven_day") {
        if let Some(w) = window_from_bucket("Weekly limit", obj) {
            windows.push(w);
        }
    }

    // Prefer structured limits array when present.
    if windows.is_empty() {
        if let Some(limits) = body.get("limits").and_then(|v| v.as_array()) {
            for limit in limits {
                let label = match limit.get("kind").and_then(|v| v.as_str()) {
                    Some("session") => "Current session",
                    Some("weekly_all") => "Weekly limit",
                    Some(other) => other,
                    None => continue,
                };
                let pct = limit
                    .get("percent")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(0.0)
                    .clamp(0.0, 100.0);
                let resets_at = limit
                    .get("resets_at")
                    .and_then(|v| v.as_str())
                    .and_then(parse_rfc3339);
                windows.push(UsageWindow {
                    label: label.into(),
                    used_pct: pct,
                    resets_at,
                });
            }
        }
    }

    if windows.is_empty() {
        windows.push(UsageWindow {
            label: "Usage".into(),
            used_pct: 0.0,
            resets_at: None,
        });
    }

    UsageReading {
        provider: ProviderId::ClaudeCode,
        display_name: ProviderId::ClaudeCode.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: None,
    }
}

fn window_from_bucket(label: &str, obj: &Value) -> Option<UsageWindow> {
    #[derive(Deserialize)]
    struct Bucket {
        utilization: Option<f64>,
        resets_at: Option<String>,
    }
    let bucket: Bucket = serde_json::from_value(obj.clone()).ok()?;
    Some(UsageWindow {
        label: label.into(),
        used_pct: bucket.utilization.unwrap_or(0.0).clamp(0.0, 100.0),
        resets_at: bucket.resets_at.as_deref().and_then(parse_rfc3339),
    })
}

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}
