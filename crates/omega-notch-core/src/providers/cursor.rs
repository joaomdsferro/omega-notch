use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Local, NaiveDate, TimeZone, Utc};
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::chats::{pretty_model, HISTORY_DAYS};
use crate::paths;
use crate::protocol::{
    DayModelTokens, DayTokens, Fidelity, ModelTokens, ProviderId, ReadingStatus, SessionDayTokens,
    TokenStats, TokenTotals, UsageReading, UsageWindow,
};

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

// ---------------------------------------------------------------------------
// Token totals from Cursor's usage-events dashboard API
// ---------------------------------------------------------------------------

const USAGE_EVENTS_URL: &str =
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents";
/// How long a successful fetch stands in for the next activity scan. The
/// endpoint paginates and can take a few seconds; chats still refresh locally.
const TOKEN_CACHE_TTL: Duration = Duration::from_secs(180);
const EVENT_PAGE_SIZE: u32 = 1000;
const EVENT_MAX_PAGES: u32 = 8;

struct TokenCache {
    at: Instant,
    stats: TokenStats,
    by_chat: HashMap<String, TokenTotals>,
}

static TOKEN_CACHE: Mutex<Option<TokenCache>> = Mutex::new(None);
static TOKEN_FETCHING: AtomicBool = AtomicBool::new(false);

/// Today's and this week's Cursor tokens, plus a per-composer map for the chat
/// list. Grok Bot events that share the same bill are dropped — they have
/// their own provider. Cached so the 2-second activity poll stays light: a
/// stale cache is returned at once while a background refresh runs.
pub async fn token_activity() -> Option<(TokenStats, HashMap<String, TokenTotals>)> {
    let cached = TOKEN_CACHE.lock().ok().and_then(|guard| {
        guard
            .as_ref()
            .map(|c| (c.at, c.stats.clone(), c.by_chat.clone()))
    });

    if let Some((at, stats, by_chat)) = cached {
        if at.elapsed() < TOKEN_CACHE_TTL {
            return Some((stats, by_chat));
        }
        // Stale but usable: refresh out of band so chats keep polling.
        spawn_token_refresh();
        return Some((stats, by_chat));
    }

    match fetch_token_activity().await {
        Ok(result) => {
            store_token_cache(&result);
            Some(result)
        }
        Err(err) => {
            tracing::warn!(error = %err, "could not fetch Cursor token usage");
            None
        }
    }
}

fn store_token_cache(result: &(TokenStats, HashMap<String, TokenTotals>)) {
    if let Ok(mut guard) = TOKEN_CACHE.lock() {
        *guard = Some(TokenCache {
            at: Instant::now(),
            stats: result.0.clone(),
            by_chat: result.1.clone(),
        });
    }
}

fn spawn_token_refresh() {
    if TOKEN_FETCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    tokio::spawn(async {
        match fetch_token_activity().await {
            Ok(result) => store_token_cache(&result),
            Err(err) => tracing::warn!(error = %err, "could not refresh Cursor token usage"),
        }
        TOKEN_FETCHING.store(false, Ordering::SeqCst);
    });
}

async fn fetch_token_activity() -> Result<(TokenStats, HashMap<String, TokenTotals>), ProviderError>
{
    let token = read_access_token()?;
    let client = reqwest::Client::builder()
        .user_agent(crate::USER_AGENT)
        .timeout(Duration::from_secs(45))
        .build()
        .map_err(|e| ProviderError::Other(e.into()))?;

    let today = Local::now().date_naive();
    let first_day = today - ChronoDuration::days(HISTORY_DAYS - 1);
    let start_ms = local_midnight_ms(first_day).unwrap_or(0);
    let end_ms = Utc::now().timestamp_millis();

    let mut events = Vec::new();
    let mut total: Option<u64> = None;
    for page in 1..=EVENT_MAX_PAGES {
        let body = serde_json::json!({
            "teamId": 0,
            "startDate": start_ms.to_string(),
            "endDate": end_ms.to_string(),
            "page": page,
            "pageSize": EVENT_PAGE_SIZE,
        });
        let response = client
            .post(USAGE_EVENTS_URL)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .header("Connect-Protocol-Version", "1")
            .json(&body)
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
            let text = response.text().await.unwrap_or_default();
            return Err(ProviderError::Message(format!(
                "Cursor usage events HTTP {status}: {text}"
            )));
        }

        let page_body: FilteredUsage = response
            .json()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;
        if total.is_none() {
            total = page_body.total_usage_events_count;
        }
        let batch = page_body.usage_events_display.unwrap_or_default();
        let batch_len = batch.len() as u64;
        events.extend(batch);
        let reached = total.is_some_and(|n| events.len() as u64 >= n);
        if batch_len < EVENT_PAGE_SIZE as u64 || reached {
            break;
        }
    }

    Ok(stats_from_events(&events, today))
}

fn stats_from_events(
    events: &[UsageEvent],
    today: NaiveDate,
) -> (TokenStats, HashMap<String, TokenTotals>) {
    let first_day = today - ChronoDuration::days(HISTORY_DAYS - 1);
    let mut per_day: HashMap<NaiveDate, TokenTotals> = HashMap::new();
    let mut per_day_model: HashMap<(NaiveDate, String), TokenTotals> = HashMap::new();
    let mut per_session: HashMap<(String, NaiveDate, String), TokenTotals> = HashMap::new();
    let mut models_today: HashMap<String, u64> = HashMap::new();
    let mut by_chat: HashMap<String, TokenTotals> = HashMap::new();

    for event in events {
        let model_id = event.model.as_deref().unwrap_or("");
        if !counts_as_cursor_model(model_id) {
            continue;
        }
        let Some(tokens) = event.token_usage.as_ref().map(EventTokens::totals) else {
            continue;
        };
        if tokens.total() == 0 {
            continue;
        }
        let Some(at) = event_timestamp(event.timestamp.as_ref()) else {
            continue;
        };
        let day = at.with_timezone(&Local).date_naive();
        if day < first_day || day > today {
            continue;
        }
        let label = cursor_usage_model(model_id);
        per_day.entry(day).or_default().add(&tokens);
        per_day_model
            .entry((day, label.clone()))
            .or_default()
            .add(&tokens);
        if let Some(chat_id) = event
            .conversation_id
            .as_deref()
            .filter(|id| !id.is_empty() && *id != "null")
        {
            by_chat.entry(chat_id.to_string()).or_default().add(&tokens);
            per_session
                .entry((chat_id.to_string(), day, label.clone()))
                .or_default()
                .add(&tokens);
        }
        if day == today {
            *models_today.entry(label).or_default() += tokens.total();
        }
    }

    let mut week = TokenTotals::default();
    let mut daily = Vec::with_capacity(HISTORY_DAYS as usize);
    for offset in 0..HISTORY_DAYS {
        let day = first_day + ChronoDuration::days(offset);
        let tokens = per_day.get(&day).copied().unwrap_or_default();
        week.add(&tokens);
        daily.push(DayTokens {
            date: day.format("%Y-%m-%d").to_string(),
            total: tokens.total(),
        });
    }

    let mut models_today: Vec<ModelTokens> = models_today
        .into_iter()
        .filter(|(_, total)| *total > 0)
        .map(|(model, total)| ModelTokens { model, total })
        .collect();
    models_today.sort_by(|a, b| b.total.cmp(&a.total).then(a.model.cmp(&b.model)));

    let mut days_by_model: Vec<DayModelTokens> = per_day_model
        .into_iter()
        .filter(|(_, tokens)| tokens.total() > 0)
        .map(|((day, model), tokens)| DayModelTokens {
            date: day.format("%Y-%m-%d").to_string(),
            model,
            tokens,
        })
        .collect();
    days_by_model.sort_by(|a, b| a.date.cmp(&b.date).then(a.model.cmp(&b.model)));

    let mut session_days: Vec<SessionDayTokens> = per_session
        .into_iter()
        .filter(|(_, tokens)| tokens.total() > 0)
        .map(|((session_id, day, model), tokens)| SessionDayTokens {
            session_id,
            date: day.format("%Y-%m-%d").to_string(),
            model,
            tokens,
        })
        .collect();
    session_days.sort_by(|a, b| {
        (&a.session_id, &a.date, &a.model).cmp(&(&b.session_id, &b.date, &b.model))
    });

    let stats = TokenStats {
        provider: ProviderId::Cursor,
        today: per_day.get(&today).copied().unwrap_or_default(),
        week,
        daily,
        models_today,
        days_by_model,
        session_days,
        session_meta: Vec::new(),
    };
    (stats, by_chat)
}

fn counts_as_cursor_model(model: &str) -> bool {
    !model.is_empty() && !model.starts_with("grok-bot")
}

fn cursor_usage_model(id: &str) -> String {
    if id.eq_ignore_ascii_case("default") {
        "Auto".into()
    } else {
        pretty_model(id)
    }
}

fn local_midnight_ms(day: NaiveDate) -> Option<i64> {
    let naive = day.and_hms_opt(0, 0, 0)?;
    let local = Local.from_local_datetime(&naive).earliest()?;
    Some(local.with_timezone(&Utc).timestamp_millis())
}

fn event_timestamp(value: Option<&Value>) -> Option<DateTime<Utc>> {
    let value = value?;
    let ms = value
        .as_i64()
        .or_else(|| value.as_u64().map(|n| n as i64))
        .or_else(|| value.as_str()?.parse().ok())?;
    Utc.timestamp_millis_opt(ms).single()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FilteredUsage {
    usage_events_display: Option<Vec<UsageEvent>>,
    total_usage_events_count: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageEvent {
    timestamp: Option<Value>,
    model: Option<String>,
    token_usage: Option<EventTokens>,
    conversation_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventTokens {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_tokens: Option<u64>,
    cache_write_tokens: Option<u64>,
}

impl EventTokens {
    fn totals(&self) -> TokenTotals {
        TokenTotals {
            input: self.input_tokens.unwrap_or(0),
            output: self.output_tokens.unwrap_or(0),
            cache_read: self.cache_read_tokens.unwrap_or(0),
            cache_write: self.cache_write_tokens.unwrap_or(0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn usage_events_skip_grok_bot_and_bucket_by_day() {
        let today = NaiveDate::from_ymd_opt(2026, 10, 20).unwrap();
        let today_ms = Local
            .from_local_datetime(&today.and_hms_opt(12, 0, 0).unwrap())
            .earliest()
            .unwrap()
            .timestamp_millis();
        let events = vec![
            UsageEvent {
                timestamp: Some(json!(today_ms)),
                model: Some("default".into()),
                token_usage: Some(EventTokens {
                    input_tokens: Some(100),
                    output_tokens: Some(20),
                    cache_read_tokens: Some(50),
                    cache_write_tokens: Some(5),
                }),
                conversation_id: Some("chat-1".into()),
            },
            UsageEvent {
                timestamp: Some(json!(today_ms.to_string())),
                model: Some("grok-bot-default".into()),
                token_usage: Some(EventTokens {
                    input_tokens: Some(999),
                    output_tokens: Some(999),
                    cache_read_tokens: Some(999),
                    cache_write_tokens: Some(0),
                }),
                conversation_id: Some("bot-1".into()),
            },
            UsageEvent {
                timestamp: Some(json!(today_ms)),
                model: Some("composer-2.5-fast".into()),
                token_usage: Some(EventTokens {
                    input_tokens: Some(10),
                    output_tokens: Some(2),
                    cache_read_tokens: Some(0),
                    cache_write_tokens: Some(0),
                }),
                conversation_id: Some("chat-1".into()),
            },
        ];
        let (stats, by_chat) = stats_from_events(&events, today);
        assert_eq!(stats.today.input, 110);
        assert_eq!(stats.today.output, 22);
        assert_eq!(stats.today.cache_read, 50);
        assert_eq!(stats.today.cache_write, 5);
        assert_eq!(by_chat["chat-1"].input, 110);
        assert!(!by_chat.contains_key("bot-1"));
        assert!(stats
            .models_today
            .iter()
            .any(|m| m.model == "Auto" && m.total > 0));
    }
}
