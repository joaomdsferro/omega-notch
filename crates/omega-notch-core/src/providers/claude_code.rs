use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::Value;

use super::profiles::Profile;
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

#[derive(Default)]
struct Throttle {
    /// Also kept on disk, so an engine restart neither asks again at once
    /// nor has nothing to show when that first request is refused.
    last_ok: Option<UsageReading>,
    loaded: bool,
    blocked_until: Option<Instant>,
    backoff: Option<Duration>,
}

/// One per account: the last reading, backoff and rate limit of a profile say
/// nothing about another profile.
static THROTTLES: Mutex<Option<HashMap<String, Throttle>>> = Mutex::new(None);

/// The default account keeps the file it always had; a profile gets its own.
fn saved_path(profile: &Profile) -> PathBuf {
    let name = match &profile.slug {
        Some(slug) => format!("claude-usage-{slug}.json"),
        None => "claude-usage.json".to_string(),
    };
    paths::app_data_dir().join(name)
}

fn load_saved(profile: &Profile) -> Option<UsageReading> {
    let raw = std::fs::read_to_string(saved_path(profile)).ok()?;
    serde_json::from_str(&raw).ok()
}

/// Written to a temporary file, then moved over the old one.
fn save(profile: &Profile, reading: &UsageReading) -> anyhow::Result<()> {
    paths::create_private_dir(&paths::app_data_dir())?;
    let path = saved_path(profile);
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(reading)?)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

enum Failure {
    RateLimited(Option<Duration>),
    Other(ProviderError),
}

impl Throttle {
    /// The last reading, if it is recent enough to answer in place of a request.
    fn reusable(&self, max_age: Duration) -> Option<UsageReading> {
        let reading = self.last_ok.as_ref()?;
        let now = Utc::now();
        // A window that has rolled over since makes the numbers wrong.
        let rolled_over = reading
            .windows
            .iter()
            .any(|w| w.resets_at.is_some_and(|t| t <= now));
        // A reading from the future (the clock went back) is not trusted.
        let age = (now - reading.fetched_at).to_std().ok()?;
        (age < max_age && !rolled_over).then(|| reading.clone())
    }

    fn rate_limited(&self) -> Result<UsageReading, ProviderError> {
        self.reusable(QUIET_FOR)
            .ok_or_else(|| ProviderError::Message(RATE_LIMITED.into()))
    }
}

impl ClaudeCodeProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let profile = Profile {
            id: ProviderId::ClaudeCode,
            base: ProviderId::ClaudeCode.as_str(),
            slug: None,
            dir: paths::claude_home(),
        };
        Self::fetch_profile(&profile).await
    }

    /// One account's reading. The throttle is per profile: a 429 on a work
    /// account must not hide the personal account's numbers.
    pub async fn fetch_profile(profile: &Profile) -> Result<UsageReading, ProviderError> {
        let key = profile.id.as_str().to_string();
        {
            let mut throttles = THROTTLES.lock().unwrap();
            let throttle = throttles
                .get_or_insert_with(HashMap::new)
                .entry(key.clone())
                .or_default();
            if !throttle.loaded {
                throttle.loaded = true;
                throttle.last_ok = load_saved(profile);
            }
            if let Some(reading) = throttle.reusable(MIN_INTERVAL) {
                return Ok(reading);
            }
            if throttle.blocked_until.is_some_and(|t| Instant::now() < t) {
                return throttle.rate_limited();
            }
        }

        let result = Self::fetch_remote(profile).await;

        let mut throttles = THROTTLES.lock().unwrap();
        let throttle = throttles
            .get_or_insert_with(HashMap::new)
            .entry(key)
            .or_default();
        match result {
            Ok(reading) => {
                if let Err(err) = save(profile, &reading) {
                    tracing::warn!(error = %err, "could not save the Claude usage reading");
                }
                throttle.last_ok = Some(reading.clone());
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

    async fn fetch_remote(profile: &Profile) -> Result<UsageReading, Failure> {
        // Reading the Keychain can wait on the user answering a prompt.
        let dir = profile.dir.clone();
        let keychain = profile.slug.is_none();
        let token = tokio::task::spawn_blocking(move || read_oauth_token(&dir, keychain))
            .await
            .map_err(|e| Failure::Other(ProviderError::Other(e.into())))?
            .map_err(Failure::Other)?;
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

        Ok(parse_usage(body, &profile.id, &profile.display_name()))
    }
}

/// Reads `<dir>/.credentials.json`, falling back to the login Keychain for the
/// default account only. A profile's Keychain entry is named after a hash of
/// its path, which this build does not compute; profiles signed in through
/// Claude Code's keychain storage need `claude setup-token` to keep a file.
fn read_oauth_token(dir: &Path, keychain: bool) -> Result<String, ProviderError> {
    let path = dir.join(".credentials.json");
    let raw = if path.exists() {
        std::fs::read_to_string(&path).map_err(|e| ProviderError::Other(e.into()))?
    } else if keychain {
        read_keychain_credentials()?
    } else {
        return Err(ProviderError::NeedsAuth(format!(
            "No {} — sign in with CLAUDE_CONFIG_DIR={} claude",
            path.display(),
            dir.display()
        )));
    };
    parse_oauth_token(&raw)
}

#[cfg(not(target_os = "macos"))]
fn read_keychain_credentials() -> Result<String, ProviderError> {
    Err(ProviderError::NeedsAuth(
        "No ~/.claude/.credentials.json — sign in with Claude Code".into(),
    ))
}

/// After the user turns the Keychain prompt down, it is not shown again for
/// this long, rather than on every refresh.
#[cfg(target_os = "macos")]
const KEYCHAIN_QUIET_FOR: Duration = Duration::from_secs(3600);
/// How long a refresh waits for the Keychain. An allowed read takes a few
/// milliseconds; a prompt can stay up for as long as the user ignores it, and
/// the other providers must not wait on it.
#[cfg(target_os = "macos")]
const KEYCHAIN_WAIT: Duration = Duration::from_secs(2);

#[cfg(target_os = "macos")]
enum KeychainRead {
    Idle,
    /// A read is under way, perhaps behind a prompt; its result lands in `Done`.
    Asking,
    Done(Result<String, ProviderError>),
    DeniedAt(Instant),
}

#[cfg(target_os = "macos")]
static KEYCHAIN: (Mutex<KeychainRead>, std::sync::Condvar) =
    (Mutex::new(KeychainRead::Idle), std::sync::Condvar::new());

#[cfg(target_os = "macos")]
fn keychain_denied() -> ProviderError {
    ProviderError::NeedsAuth(
        "Keychain access was declined — allow Omega Notch to read the Claude Code sign-in".into(),
    )
}

/// Claude Code on macOS keeps the same JSON as the Linux file in the login
/// Keychain. The read runs on its own thread, so a prompt left unanswered
/// only delays this provider; its answer is picked up by the next refresh.
/// The token is only ever held in memory.
#[cfg(target_os = "macos")]
fn read_keychain_credentials() -> Result<String, ProviderError> {
    let (lock, ready) = &KEYCHAIN;
    let mut state = lock.lock().unwrap();
    match *state {
        KeychainRead::DeniedAt(at) if at.elapsed() < KEYCHAIN_QUIET_FOR => {
            return Err(keychain_denied());
        }
        KeychainRead::Idle | KeychainRead::DeniedAt(_) => {
            *state = KeychainRead::Asking;
            std::thread::spawn(|| {
                let result = ask_keychain();
                let (lock, ready) = &KEYCHAIN;
                *lock.lock().unwrap() = result;
                ready.notify_all();
            });
        }
        KeychainRead::Asking | KeychainRead::Done(_) => {}
    }
    let (mut state, _) = ready
        .wait_timeout_while(state, KEYCHAIN_WAIT, |s| matches!(s, KeychainRead::Asking))
        .unwrap();
    match std::mem::replace(&mut *state, KeychainRead::Idle) {
        KeychainRead::Done(result) => result,
        KeychainRead::DeniedAt(at) => {
            *state = KeychainRead::DeniedAt(at);
            Err(keychain_denied())
        }
        KeychainRead::Asking => {
            *state = KeychainRead::Asking;
            Err(ProviderError::NeedsAuth(
                "Waiting for you to allow Keychain access to the Claude Code sign-in".into(),
            ))
        }
        KeychainRead::Idle => unreachable!("a read was started above"),
    }
}

#[cfg(target_os = "macos")]
fn ask_keychain() -> KeychainRead {
    use crate::platform::{keychain_password, KeychainError};

    match keychain_password(paths::CLAUDE_KEYCHAIN_SERVICE) {
        Ok(data) => {
            KeychainRead::Done(String::from_utf8(data).map_err(|e| ProviderError::Other(e.into())))
        }
        Err(KeychainError::NotFound) => KeychainRead::Done(Err(ProviderError::NeedsAuth(
            "No Claude Code sign-in in the Keychain — sign in with Claude Code".into(),
        ))),
        Err(KeychainError::Denied) => KeychainRead::DeniedAt(Instant::now()),
        Err(KeychainError::Other(message)) => KeychainRead::Done(Err(ProviderError::Message(
            format!("Could not read the Keychain: {message}"),
        ))),
    }
}

fn parse_oauth_token(raw: &str) -> Result<String, ProviderError> {
    let value: Value = serde_json::from_str(raw).map_err(|e| ProviderError::Other(e.into()))?;
    let token = value
        .pointer("/claudeAiOauth/accessToken")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ProviderError::NeedsAuth("Claude OAuth token missing — sign in with Claude Code".into())
        })?;

    Ok(token.to_string())
}

fn parse_usage(body: Value, provider: &ProviderId, display_name: &str) -> UsageReading {
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
        provider: provider.clone(),
        display_name: display_name.to_string(),
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
