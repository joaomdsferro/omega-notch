//! What opencode keeps on disk: the SQLite database under
//! `~/.local/share/opencode` holds every session and message, and each
//! assistant turn records the sub-provider (Zen, Anthropic, GitHub Copilot…)
//! and model it ran on, with token counts. Nothing here talks to the network
//! and nothing is written back.
//!
//! opencode's own provider id reads as "Zen", its metered service; any other
//! id is the vendor the turn actually ran on. Model labels carry both, as in
//! `Sonnet 4.5 · Anthropic`.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use chrono::{DateTime, Duration as ChronoDuration, Local, NaiveDate, TimeZone, Utc};
use rusqlite::Connection;
use serde::Deserialize;

use crate::chats::{clean_title, folder_name, pretty_model, HISTORY_DAYS, MAX_CHATS};
use crate::paths;
use crate::protocol::{
    ChatSummary, DayModelTokens, DayTokens, ModelTokens, ProviderId, SessionDayTokens, SessionKind,
    SessionMeta, TokenStats, TokenTotals,
};

/// The opencode provider id counts as its own metered service.
const ZEN: &str = "opencode";

fn connect() -> Option<Connection> {
    let path = paths::opencode_db();
    if !path.exists() {
        return None;
    }
    let uri = format!("file:{}?mode=ro", path.display());
    let conn = Connection::open_with_flags(
        &uri,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )
    .ok()?;
    let _ = conn.busy_timeout(Duration::from_millis(400));
    Some(conn)
}

/// The same database, for the other readers of opencode's sign-ins.
pub(crate) fn read_connection() -> Option<Connection> {
    connect()
}

/// One assistant turn: who billed it, how big it was, and when.
struct Turn {
    session: String,
    at: DateTime<Utc>,
    provider: String,
    model: String,
    tokens: TokenTotals,
}

/// A session as the table keeps it; `parent` is set for subagents.
struct SessionRow {
    id: String,
    parent: Option<String>,
    title: String,
    directory: String,
    model: Option<SessionModel>,
    input: u64,
    output: u64,
    reasoning: u64,
    cache_read: u64,
    cache_write: u64,
    additions: Option<u64>,
    deletions: Option<u64>,
    updated_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct SessionModel {
    id: String,
    #[serde(rename = "providerID")]
    provider: Option<String>,
}

/// Lifetime tokens, as the session totals them; reasoning bills as output.
fn session_tokens(session: &SessionRow) -> TokenTotals {
    TokenTotals {
        input: session.input,
        output: session.output + session.reasoning,
        cache_read: session.cache_read,
        cache_write: session.cache_write,
    }
}

fn read_sessions(conn: &Connection) -> Vec<SessionRow> {
    let Ok(mut statement) = conn.prepare(
        "SELECT id, parent_id, title, directory, model,
                tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write,
                summary_additions, summary_deletions, time_updated
         FROM session",
    ) else {
        return Vec::new();
    };
    let rows = statement.query_map([], |row| {
        let non_negative = |i: usize| -> rusqlite::Result<u64> {
            Ok(row.get::<_, Option<i64>>(i)?.unwrap_or(0).max(0) as u64)
        };
        let optional = |i: usize| -> rusqlite::Result<Option<u64>> {
            Ok(row
                .get::<_, Option<i64>>(i)?
                .filter(|value| *value >= 0)
                .map(|value| value as u64))
        };
        let model = row
            .get::<_, Option<String>>(4)?
            .and_then(|raw| serde_json::from_str(&raw).ok());
        Ok(SessionRow {
            id: row.get(0)?,
            parent: row.get(1)?,
            title: row.get(2)?,
            directory: row.get(3)?,
            model,
            input: non_negative(5)?,
            output: non_negative(6)?,
            reasoning: non_negative(7)?,
            cache_read: non_negative(8)?,
            cache_write: non_negative(9)?,
            additions: optional(10)?,
            deletions: optional(11)?,
            updated_at: row
                .get::<_, Option<i64>>(12)?
                .and_then(utc_from_ms)
                .unwrap_or(DateTime::<Utc>::MIN_UTC),
        })
    });
    let Ok(rows) = rows else {
        return Vec::new();
    };
    rows.flatten().collect()
}

/// Assistant turns since `since_ms`, each still naming its sub-provider.
fn read_turns(conn: &Connection, since_ms: i64) -> Vec<Turn> {
    let Ok(mut statement) = conn.prepare(
        "SELECT session_id,
                COALESCE(json_extract(data, '$.time.created'), time_created),
                json_extract(data, '$.providerID'),
                json_extract(data, '$.modelID'),
                json_extract(data, '$.tokens.input'),
                json_extract(data, '$.tokens.output'),
                json_extract(data, '$.tokens.reasoning'),
                json_extract(data, '$.tokens.cache.read'),
                json_extract(data, '$.tokens.cache.write')
         FROM message
         WHERE json_extract(data, '$.role') = 'assistant' AND time_created >= ?1",
    ) else {
        return Vec::new();
    };
    let rows = statement.query_map([since_ms], |row| {
        let non_negative = |i: usize| -> rusqlite::Result<u64> {
            Ok(row.get::<_, Option<i64>>(i)?.unwrap_or(0).max(0) as u64)
        };
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<i64>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            non_negative(4)?,
            non_negative(5)?,
            non_negative(6)?,
            non_negative(7)?,
            non_negative(8)?,
        ))
    });
    let Ok(rows) = rows else {
        return Vec::new();
    };
    rows.flatten()
        .filter_map(
            |(session, ms, provider, model, input, output, reasoning, read, write)| {
                Some(Turn {
                    session,
                    at: utc_from_ms(ms?)?,
                    provider: provider.unwrap_or_else(|| ZEN.to_string()),
                    model: model.unwrap_or_default(),
                    tokens: TokenTotals {
                        input,
                        output: output + reasoning,
                        cache_read: read,
                        cache_write: write,
                    },
                })
            },
        )
        .collect()
}

/// How many prompts each session holds, for its chat row.
fn user_message_counts(conn: &Connection) -> HashMap<String, u32> {
    let Ok(mut statement) = conn.prepare(
        "SELECT session_id, COUNT(*) FROM message
         WHERE json_extract(data, '$.role') = 'user' GROUP BY session_id",
    ) else {
        return HashMap::new();
    };
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?.clamp(0, u32::MAX as i64) as u32,
        ))
    });
    let Ok(rows) = rows else {
        return HashMap::new();
    };
    rows.flatten().collect()
}

/// The sub-provider of the newest billed turn, whatever its age.
fn newest_sub_provider(conn: &Connection) -> Option<String> {
    conn.query_row(
        "SELECT json_extract(data, '$.providerID') FROM message
         WHERE json_extract(data, '$.role') = 'assistant'
           AND json_extract(data, '$.tokens.input') IS NOT NULL
         ORDER BY time_created DESC LIMIT 1",
        [],
        |row| row.get::<_, Option<String>>(0),
    )
    .ok()
    .flatten()
}

fn utc_from_ms(ms: i64) -> Option<DateTime<Utc>> {
    Utc.timestamp_millis_opt(ms).single()
}

/// Midnight local time on `day`, as an epoch in milliseconds.
fn local_midnight_ms(day: NaiveDate) -> Option<i64> {
    let naive = day.and_hms_opt(0, 0, 0)?;
    let local = Local.from_local_datetime(&naive).earliest()?;
    Some(local.with_timezone(&Utc).timestamp_millis())
}

fn empty_stats(today: NaiveDate) -> TokenStats {
    let first_day = today - ChronoDuration::days(HISTORY_DAYS - 1);
    let daily = (0..HISTORY_DAYS)
        .map(|offset| {
            let day = first_day + ChronoDuration::days(offset);
            DayTokens {
                date: day.format("%Y-%m-%d").to_string(),
                total: 0,
            }
        })
        .collect();
    TokenStats {
        provider: ProviderId::OpenCode,
        today: TokenTotals::default(),
        week: TokenTotals::default(),
        daily,
        models_today: Vec::new(),
        days_by_model: Vec::new(),
        session_days: Vec::new(),
        session_meta: Vec::new(),
    }
}

/// Recent chats and the last `HISTORY_DAYS` of tokens, as the dashboard and
/// the live snapshot read them.
pub fn activity() -> (Vec<ChatSummary>, TokenStats) {
    let Some(conn) = connect() else {
        return (Vec::new(), empty_stats(Local::now().date_naive()));
    };
    activity_from(&conn, Local::now())
}

/// `now` is the clock the days are counted by; the tests pin it, so a turn
/// that lands on the other side of midnight cannot make the day before it.
fn activity_from(conn: &Connection, now: DateTime<Local>) -> (Vec<ChatSummary>, TokenStats) {
    let today = now.date_naive();
    let first_day = today - ChronoDuration::days(HISTORY_DAYS - 1);
    let mut stats = empty_stats(today);
    let sessions = read_sessions(conn);
    if sessions.is_empty() {
        return (Vec::new(), stats);
    }
    let by_id: HashMap<&str, &SessionRow> = sessions.iter().map(|s| (s.id.as_str(), s)).collect();
    let root_of = |id: &str| -> String {
        let mut current = id;
        for _ in 0..8 {
            match by_id.get(current).and_then(|s| s.parent.as_deref()) {
                Some(parent) => current = parent,
                None => break,
            }
        }
        current.to_string()
    };

    let Some(since) = local_midnight_ms(first_day) else {
        return (Vec::new(), stats);
    };
    let turns = read_turns(conn, since);

    let mut per_day: HashMap<NaiveDate, TokenTotals> = HashMap::new();
    let mut per_day_model: HashMap<(NaiveDate, String), TokenTotals> = HashMap::new();
    let mut per_session: HashMap<(String, NaiveDate, String), TokenTotals> = HashMap::new();
    let mut models_today: HashMap<String, u64> = HashMap::new();
    for turn in &turns {
        let day = turn.at.with_timezone(&Local).date_naive();
        if day < first_day || day > today {
            continue;
        }
        let label = model_label(&turn.model, &turn.provider);
        per_day.entry(day).or_default().add(&turn.tokens);
        per_day_model
            .entry((day, label.clone()))
            .or_default()
            .add(&turn.tokens);
        per_session
            .entry((root_of(&turn.session), day, label.clone()))
            .or_default()
            .add(&turn.tokens);
        if day == today {
            *models_today.entry(label).or_default() += turn.tokens.total();
        }
    }

    let mut week = TokenTotals::default();
    for offset in 0..HISTORY_DAYS {
        let day = first_day + ChronoDuration::days(offset);
        let tokens = per_day.get(&day).copied().unwrap_or_default();
        week.add(&tokens);
        stats.daily[offset as usize].total = tokens.total();
    }
    stats.today = per_day.get(&today).copied().unwrap_or_default();
    stats.week = week;

    let mut models_today: Vec<ModelTokens> = models_today
        .into_iter()
        .filter(|(_, total)| *total > 0)
        .map(|(model, total)| ModelTokens { model, total })
        .collect();
    models_today.sort_by(|a, b| b.total.cmp(&a.total).then(a.model.cmp(&b.model)));
    stats.models_today = models_today;

    stats.days_by_model = {
        let mut rows: Vec<DayModelTokens> = per_day_model
            .into_iter()
            .filter(|(_, tokens)| tokens.total() > 0)
            .map(|((day, model), tokens)| DayModelTokens {
                date: day.format("%Y-%m-%d").to_string(),
                model,
                tokens,
            })
            .collect();
        rows.sort_by(|a, b| a.date.cmp(&b.date).then(a.model.cmp(&b.model)));
        rows
    };

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
    let live: HashSet<&str> = session_days.iter().map(|r| r.session_id.as_str()).collect();
    let mut session_meta: Vec<SessionMeta> = sessions
        .iter()
        .filter(|s| s.parent.is_none() && live.contains(s.id.as_str()))
        .filter_map(|s| {
            Some(SessionMeta {
                session_id: s.id.clone(),
                title: chat_title(s)?,
                project: project_of(s),
                cwd: (!s.directory.is_empty()).then(|| s.directory.clone()),
                surface: None,
                updated_at: s.updated_at,
            })
        })
        .collect();
    session_meta.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    stats.session_days = session_days;
    stats.session_meta = session_meta;

    // Chats: root sessions only, newest first, as much as a snapshot holds.
    let counts = user_message_counts(conn);
    let mut roots: Vec<&SessionRow> = sessions.iter().filter(|s| s.parent.is_none()).collect();
    roots.sort_by_key(|s| std::cmp::Reverse(s.updated_at));
    let mut chats = Vec::new();
    for session in roots {
        let tokens = session_tokens(session);
        if tokens.total() == 0 {
            continue;
        }
        chats.push(ChatSummary {
            provider: ProviderId::OpenCode,
            id: session.id.clone(),
            title: chat_title(session).unwrap_or_else(|| "Untitled".into()),
            project: project_of(session),
            cwd: (!session.directory.is_empty()).then(|| session.directory.clone()),
            model: session
                .model
                .as_ref()
                .map(|m| model_label(&m.id, m.provider.as_deref().unwrap_or_default())),
            surface: None,
            preview: None,
            avatar_shape: None,
            avatar_color: None,
            state: SessionKind::Idle,
            live: false,
            updated_at: session.updated_at,
            messages: counts.get(&session.id).copied().unwrap_or(0),
            tokens: Some(tokens),
            context_tokens: None,
            context_pct: None,
            lines_added: session.additions,
            lines_removed: session.deletions,
            unread: false,
            prompted_at: None,
            replied_at: None,
        });
        if chats.len() == MAX_CHATS {
            break;
        }
    }

    (chats, stats)
}

/// A session's own name if it has one; opencode's placeholders ("New session
/// - 2026-…") say nothing, so those fall back to the folder.
fn chat_title(session: &SessionRow) -> Option<String> {
    let raw = session.title.trim();
    if raw.starts_with("New session - ") || raw.is_empty() {
        return project_of(session);
    }
    clean_title(Some(raw)).or_else(|| project_of(session))
}

fn project_of(session: &SessionRow) -> Option<String> {
    let directory = session.directory.trim();
    if directory.is_empty() {
        return None;
    }
    Some(folder_name(directory))
}

/// What the week held, for the ring's message when no limits API exists.
pub struct RecentUsage {
    /// The sub-provider id the newest turn ran on.
    pub sub_provider: String,
    pub week: TokenTotals,
    /// The week's busiest models, labels, biggest first.
    pub top_models: Vec<(String, u64)>,
}

pub fn recent_usage() -> Option<RecentUsage> {
    let conn = connect()?;
    recent_usage_from(&conn)
}

fn recent_usage_from(conn: &Connection) -> Option<RecentUsage> {
    let today = Local::now().date_naive();
    let since = local_midnight_ms(today - ChronoDuration::days(HISTORY_DAYS - 1))?;
    let turns = read_turns(conn, since);
    let newest = newest_sub_provider(conn);
    if turns.is_empty() && newest.is_none() {
        return None;
    }

    let mut week = TokenTotals::default();
    let mut models: HashMap<String, u64> = HashMap::new();
    for turn in &turns {
        week.add(&turn.tokens);
        *models
            .entry(model_label(&turn.model, &turn.provider))
            .or_default() += turn.tokens.total();
    }
    let mut top_models: Vec<(String, u64)> = models.into_iter().collect();
    top_models.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    top_models.truncate(3);

    let sub_provider = newest
        .or_else(|| turns.last().map(|t| t.provider.clone()))
        .unwrap_or_else(|| ZEN.to_string());

    Some(RecentUsage {
        sub_provider,
        week,
        top_models,
    })
}

/// `Sonnet 4.5 · Anthropic` — the model, and where it billed.
pub fn model_label(model_id: &str, sub_provider: &str) -> String {
    let model = pretty_model(model_id);
    let provider = sub_provider_label(sub_provider);
    match (model.is_empty(), provider.is_empty()) {
        (true, _) => provider,
        (false, true) => model,
        (false, false) => format!("{model} · {provider}"),
    }
}

/// opencode's ids, written the way the vendor does; an unknown one is
/// hyphen-split and capitalised.
pub fn sub_provider_label(raw: &str) -> String {
    match raw {
        "" => return String::new(),
        "opencode" => return "Zen".into(),
        "opencode-go" => return "Go".into(),
        "anthropic" => return "Anthropic".into(),
        "openai" => return "OpenAI".into(),
        "github-copilot" => return "GitHub Copilot".into(),
        "google" => return "Google".into(),
        "xai" => return "xAI".into(),
        "openrouter" => return "OpenRouter".into(),
        "deepseek" => return "DeepSeek".into(),
        "zai" => return "Z.ai".into(),
        "minimax" => return "MiniMax".into(),
        "moonshotai" => return "Moonshot".into(),
        "mistral" => return "Mistral".into(),
        "groq" => return "Groq".into(),
        _ => {}
    }
    raw.split(['-', '_'])
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().chain(chars).collect::<String>(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// `1.2M`, `340k`, `912` — for the ring's message, where space is thin.
pub fn compact_tokens(n: u64) -> String {
    fn unit(value: f64, suffix: &str) -> String {
        let text = format!("{value:.1}");
        let text = text.strip_suffix(".0").unwrap_or(&text);
        format!("{text}{suffix}")
    }
    match n {
        0..=999 => n.to_string(),
        1_000..=999_999 => unit(n as f64 / 1_000.0, "k"),
        _ => unit(n as f64 / 1_000_000.0, "M"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE session(
                id TEXT PRIMARY KEY, parent_id TEXT, title TEXT NOT NULL,
                directory TEXT NOT NULL, model TEXT,
                tokens_input INTEGER NOT NULL DEFAULT 0,
                tokens_output INTEGER NOT NULL DEFAULT 0,
                tokens_reasoning INTEGER NOT NULL DEFAULT 0,
                tokens_cache_read INTEGER NOT NULL DEFAULT 0,
                tokens_cache_write INTEGER NOT NULL DEFAULT 0,
                summary_additions INTEGER, summary_deletions INTEGER,
                time_updated INTEGER NOT NULL
             );
             CREATE TABLE message(
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL, data TEXT NOT NULL
             );",
        )
        .unwrap();
        conn
    }

    fn add_session(
        conn: &Connection,
        id: &str,
        parent: Option<&str>,
        title: &str,
        model: &str,
        at: i64,
    ) {
        conn.execute(
            "INSERT INTO session(id, parent_id, title, directory, model,
                tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write, summary_additions, summary_deletions,
                time_updated)
             VALUES (?1, ?2, ?3, '/home/me/app', ?4, 300, 100, 40, 5000, 0, 12, 3, ?5)",
            rusqlite::params![id, parent, title, model, at - 60_000,],
        )
        .unwrap();
    }

    fn add_turn(
        conn: &Connection,
        id: &str,
        session: &str,
        role: &str,
        provider: &str,
        model: &str,
        at: i64,
    ) {
        let data = format!(
            r#"{{"role":"{role}","providerID":"{provider}","modelID":"{model}",
                "time":{{"created":{}}},"tokens":{{"input":300,"output":100,"reasoning":40,
                "cache":{{"read":5000,"write":0}}}}}}"#,
            at,
        );
        conn.execute(
            "INSERT INTO message(id, session_id, time_created, data) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![id, session, at, data],
        )
        .unwrap();
    }

    #[test]
    fn labels_name_the_model_and_where_it_billed() {
        assert_eq!(
            model_label("claude-sonnet-4-5", "anthropic"),
            "Sonnet 4.5 · Anthropic"
        );
        assert_eq!(
            model_label("deepseek-v4.1-flash-free", "opencode"),
            "Deepseek V4.1 Flash Free · Zen"
        );
        assert_eq!(model_label("big-pickle", ""), "Big Pickle");
        assert_eq!(sub_provider_label("github-copilot"), "GitHub Copilot");
        assert_eq!(sub_provider_label("some-new-vendor"), "Some New Vendor");
    }

    #[test]
    fn tokens_are_compact_enough_for_the_ring() {
        assert_eq!(compact_tokens(0), "0");
        assert_eq!(compact_tokens(912), "912");
        assert_eq!(compact_tokens(1_000), "1k");
        assert_eq!(compact_tokens(1_234_567), "1.2M");
        assert_eq!(compact_tokens(12_345), "12.3k");
    }

    #[test]
    fn chats_fold_subagents_into_their_parent_and_keep_labels() {
        let conn = fixture();
        // One clock for the fixture and the code under test: a turn written
        // half a second before midnight belongs to the day before, and the
        // test would fail for a day that never happened.
        let now = Local::now();
        let at = now.timestamp_millis();
        add_session(
            &conn,
            "ses_root",
            None,
            "New session - 2026-10-19T19:22:52.028Z",
            r#"{"id":"deepseek-v4.1-flash-free","providerID":"opencode"}"#,
            at,
        );
        add_session(
            &conn,
            "ses_child",
            Some("ses_root"),
            "Explore the provider system (@explore subagent)",
            r#"{"id":"deepseek-v4.1-flash-free","providerID":"opencode"}"#,
            at,
        );
        conn.execute(
            "UPDATE session SET tokens_input = 0, tokens_output = 0, tokens_reasoning = 0,
                tokens_cache_read = 0 WHERE id = 'ses_child'",
            [],
        )
        .unwrap();
        add_turn(
            &conn,
            "m1",
            "ses_root",
            "user",
            "opencode",
            "deepseek-v4.1-flash-free",
            at,
        );
        add_turn(
            &conn,
            "m2",
            "ses_root",
            "assistant",
            "opencode",
            "deepseek-v4.1-flash-free",
            at + 1,
        );
        add_turn(
            &conn,
            "m3",
            "ses_child",
            "assistant",
            "opencode",
            "deepseek-v4.1-flash-free",
            at + 2,
        );

        let (chats, stats) = activity_from(&conn, now);
        // The subagent is no chat of its own…
        assert_eq!(chats.len(), 1);
        assert_eq!(chats[0].id, "ses_root");
        // …its title is a placeholder, so the folder names it.
        assert_eq!(chats[0].title, "app");
        assert_eq!(chats[0].messages, 1);
        assert_eq!(
            chats[0].model.as_deref(),
            Some("Deepseek V4.1 Flash Free · Zen")
        );
        assert_eq!(chats[0].tokens.unwrap().total(), 300 + 140 + 5000);

        // Tokens include the subagent's, labelled with its sub-provider.
        assert_eq!(stats.session_days.len(), 1);
        assert_eq!(stats.session_days[0].session_id, "ses_root");
        assert_eq!(
            stats.session_days[0].model,
            "Deepseek V4.1 Flash Free · Zen"
        );
        assert_eq!(stats.today.total(), stats.week.total());
        assert!(stats.today.total() > 0);
        assert_eq!(stats.models_today.len(), 1);
        assert_eq!(stats.session_meta.len(), 1);
        assert_eq!(stats.session_meta[0].title, "app");
        assert_eq!(stats.daily.len(), HISTORY_DAYS as usize);
    }

    #[test]
    fn the_newest_turn_names_the_sub_provider() {
        let conn = fixture();
        let now = Local::now();
        let at = now.timestamp_millis();
        add_session(
            &conn,
            "ses_root",
            None,
            "A real title",
            r#"{"id":"claude-sonnet-4-5","providerID":"anthropic"}"#,
            at,
        );
        add_turn(
            &conn,
            "m1",
            "ses_root",
            "assistant",
            "opencode",
            "big-pickle",
            at,
        );
        add_turn(
            &conn,
            "m2",
            "ses_root",
            "assistant",
            "anthropic",
            "claude-sonnet-4-5",
            at + 1,
        );
        conn.execute(
            "UPDATE message SET time_created = time_created - 60000 WHERE id = 'm1'",
            [],
        )
        .unwrap();

        let usage = recent_usage_from(&conn).unwrap();
        assert_eq!(usage.sub_provider, "anthropic");
        assert!(usage.week.total() > 0);
        assert_eq!(usage.top_models.len(), 2);
        assert_eq!(usage.top_models[0].0, "Big Pickle · Zen");
        assert_eq!(usage.top_models[1].0, "Sonnet 4.5 · Anthropic");
    }

    #[test]
    fn a_turn_at_the_edge_of_midnight_belongs_to_its_own_day() {
        let conn = fixture();
        // The last second of a day: the turn belongs to that day, whatever
        // the wall clock says when the test runs.
        let naive = Local::now().date_naive().and_hms_opt(23, 59, 59).unwrap();
        let now = Local.from_local_datetime(&naive).earliest().unwrap();
        let at = now.timestamp_millis();
        add_session(
            &conn,
            "ses_root",
            None,
            "A real title",
            r#"{"id":"claude-sonnet-4-5","providerID":"anthropic"}"#,
            at,
        );
        // Only an assistant turn counts towards the tokens.
        add_turn(
            &conn,
            "m1",
            "ses_root",
            "assistant",
            "anthropic",
            "claude-sonnet-4-5",
            at,
        );

        let (_, stats) = activity_from(&conn, now);
        assert!(stats.today.total() > 0);
        assert_eq!(stats.today.total(), stats.week.total());
        assert_eq!(
            stats.daily.last().map(|day| day.total),
            Some(stats.today.total())
        );
    }

    #[test]
    fn empty_sessions_are_not_chats() {
        let conn = fixture();
        add_session(
            &conn,
            "ses_empty",
            None,
            "New session - 2026-10-19",
            "{}",
            Local::now().timestamp_millis(),
        );
        conn.execute(
            "UPDATE session SET tokens_input = 0, tokens_output = 0, tokens_reasoning = 0,
                tokens_cache_read = 0, tokens_cache_write = 0",
            [],
        )
        .unwrap();
        let (chats, stats) = activity_from(&conn, Local::now());
        assert!(chats.is_empty());
        assert_eq!(stats.today.total(), 0);
    }
}
