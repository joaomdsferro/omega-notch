//! Persistent daily token totals for the dashboard.
//!
//! The live scan in [`crate::chats`] only keeps the last seven days in
//! memory. The dashboard wants 30–90 day trends without rescanning every
//! transcript on each open, so every activity refresh rewrites the days it
//! covers here. One row per tool and day (`daily_tokens`), one per tool, day
//! and model (`daily_model_tokens`), and one per tool, session, day and model
//! (`session_model_tokens`), all split by kind; `session_meta` names the
//! sessions. Session rows hold chat titles, so they are dropped once older
//! than the history reaches. SQLite via `rusqlite` (bundled) keeps it
//! dependency-free.

use std::collections::HashMap;
use std::path::PathBuf;

use rusqlite::{params, Connection, OptionalExtension};

use crate::paths;
use crate::pricing;
use crate::protocol::{
    DayModelTokens, HistoryPoint, ModelDayPoint, ProviderId, SessionCost, SessionDayTokens,
    SessionMeta, SessionModelCost, TokenStats, TokenTotals,
};

/// History is capped; the dashboard never asks for more than this.
pub const MAX_HISTORY_DAYS: u32 = 90;

/// The dearest sessions sent with the dashboard.
pub const MAX_SESSIONS: usize = 100;

/// Bumped when the backfill learns something new, so it runs once more.
/// v2: per-session rows.
const BACKFILL_KEY: &str = "claude_backfill_v2";

pub fn history_db_path() -> PathBuf {
    paths::app_data_dir().join("history.db")
}

fn connect() -> anyhow::Result<Connection> {
    paths::create_private_dir(&paths::app_data_dir())?;
    let conn = Connection::open(history_db_path())?;
    create_tables(&conn)?;
    Ok(conn)
}

fn create_tables(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS daily_tokens(
            provider TEXT NOT NULL,
            date TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            cache_write INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(provider, date)
        );
        CREATE TABLE IF NOT EXISTS daily_model_tokens(
            provider TEXT NOT NULL,
            date TEXT NOT NULL,
            model TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            cache_write INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(provider, date, model)
        );
        CREATE TABLE IF NOT EXISTS session_model_tokens(
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            date TEXT NOT NULL,
            model TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            cache_write INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(provider, session_id, date, model)
        );
        CREATE INDEX IF NOT EXISTS session_model_tokens_date ON session_model_tokens(date);
        CREATE TABLE IF NOT EXISTS session_meta(
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            title TEXT NOT NULL,
            project TEXT,
            cwd TEXT,
            surface TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(provider, session_id)
        );
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );",
    )
}

/// Rewrites `dates` for one tool: its per-model rows, and its per-day row
/// summed from them. Days are replaced whole, so a model that vanished from
/// a day does not linger.
fn write_days(
    tx: &rusqlite::Transaction,
    provider: &str,
    dates: &[String],
    rows: &[DayModelTokens],
) -> anyhow::Result<()> {
    let mut per_day: HashMap<&str, TokenTotals> = HashMap::new();
    for row in rows {
        per_day
            .entry(row.date.as_str())
            .or_default()
            .add(&row.tokens);
    }
    for date in dates {
        tx.execute(
            "DELETE FROM daily_model_tokens WHERE provider = ?1 AND date = ?2",
            params![provider, date],
        )?;
        match per_day.get(date.as_str()) {
            Some(t) => {
                tx.execute(
                    "INSERT INTO daily_tokens(provider, date, input, output, cache_read, cache_write)
                     VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                     ON CONFLICT(provider, date) DO UPDATE SET
                       input=excluded.input, output=excluded.output,
                       cache_read=excluded.cache_read, cache_write=excluded.cache_write",
                    params![
                        provider,
                        date,
                        t.input as i64,
                        t.output as i64,
                        t.cache_read as i64,
                        t.cache_write as i64
                    ],
                )?;
            }
            None => {
                tx.execute(
                    "DELETE FROM daily_tokens WHERE provider = ?1 AND date = ?2",
                    params![provider, date],
                )?;
            }
        }
    }
    for row in rows {
        let t = &row.tokens;
        tx.execute(
            "INSERT INTO daily_model_tokens(provider, date, model, input, output, cache_read, cache_write)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(provider, date, model) DO UPDATE SET
               input=excluded.input, output=excluded.output,
               cache_read=excluded.cache_read, cache_write=excluded.cache_write",
            params![
                provider,
                row.date,
                row.model,
                t.input as i64,
                t.output as i64,
                t.cache_read as i64,
                t.cache_write as i64
            ],
        )?;
    }
    Ok(())
}

/// Rewrites `dates` of one tool's per-session rows, like [`write_days`], and
/// names the sessions given. Rows for one key are summed: a session and its
/// subagents arrive apart. Then drops what the history no longer reaches.
fn write_session_days(
    tx: &rusqlite::Transaction,
    provider: &str,
    dates: &[String],
    rows: &[SessionDayTokens],
    meta: &[SessionMeta],
) -> anyhow::Result<()> {
    let mut merged: HashMap<(&str, &str, &str), TokenTotals> = HashMap::new();
    for row in rows {
        merged
            .entry((
                row.session_id.as_str(),
                row.date.as_str(),
                row.model.as_str(),
            ))
            .or_default()
            .add(&row.tokens);
    }
    for date in dates {
        tx.execute(
            "DELETE FROM session_model_tokens WHERE provider = ?1 AND date = ?2",
            params![provider, date],
        )?;
    }
    for ((session, date, model), t) in merged {
        tx.execute(
            "INSERT INTO session_model_tokens(provider, session_id, date, model, input, output, cache_read, cache_write)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                provider,
                session,
                date,
                model,
                t.input as i64,
                t.output as i64,
                t.cache_read as i64,
                t.cache_write as i64
            ],
        )?;
    }
    for m in meta {
        // The newest description wins: a backfill may meet an older copy.
        tx.execute(
            "INSERT INTO session_meta(provider, session_id, title, project, cwd, surface, updated_at)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(provider, session_id) DO UPDATE SET
               title=excluded.title, project=excluded.project, cwd=excluded.cwd,
               surface=excluded.surface, updated_at=excluded.updated_at
             WHERE excluded.updated_at >= session_meta.updated_at",
            params![
                provider,
                m.session_id,
                m.title,
                m.project,
                m.cwd,
                m.surface,
                m.updated_at.to_rfc3339()
            ],
        )?;
    }
    prune_sessions(tx, &cutoff(MAX_HISTORY_DAYS))?;
    Ok(())
}

/// Session rows older than `first_date`, and names no row points at.
fn prune_sessions(tx: &rusqlite::Transaction, first_date: &str) -> rusqlite::Result<()> {
    tx.execute(
        "DELETE FROM session_model_tokens WHERE date < ?1",
        params![first_date],
    )?;
    tx.execute(
        "DELETE FROM session_meta WHERE NOT EXISTS (
            SELECT 1 FROM session_model_tokens s
            WHERE s.provider = session_meta.provider AND s.session_id = session_meta.session_id)",
        [],
    )?;
    Ok(())
}

/// Rewrites the days a fresh activity scan covers. The scan re-reads every
/// transcript that touches them, so its numbers replace what is stored.
pub fn record_tokens(all: &[TokenStats]) -> anyhow::Result<()> {
    if all.is_empty() {
        return Ok(());
    }
    let mut conn = connect()?;
    let tx = conn.transaction()?;
    for stats in all {
        let dates: Vec<String> = stats.daily.iter().map(|d| d.date.clone()).collect();
        let provider = stats.provider.as_str();
        write_days(&tx, provider, &dates, &stats.days_by_model)?;
        write_session_days(
            &tx,
            provider,
            &dates,
            &stats.session_days,
            &stats.session_meta,
        )?;
    }
    tx.commit()?;
    Ok(())
}

/// Whether the one-off Claude Code backfill has already run.
pub fn backfill_done() -> anyhow::Result<bool> {
    let conn = connect()?;
    let found: Option<String> = conn
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            params![BACKFILL_KEY],
            |r| r.get(0),
        )
        .optional()?;
    Ok(found.is_some())
}

/// Stores the days a backfill found and marks it done. Only days it found
/// are touched: older history the transcripts no longer hold is kept.
pub fn record_backfill(
    provider: ProviderId,
    rows: &[DayModelTokens],
    sessions: &[SessionDayTokens],
    meta: &[SessionMeta],
) -> anyhow::Result<()> {
    let mut dates: Vec<String> = rows.iter().map(|r| r.date.clone()).collect();
    dates.dedup();
    let mut conn = connect()?;
    let tx = conn.transaction()?;
    write_days(&tx, provider.as_str(), &dates, rows)?;
    write_session_days(&tx, provider.as_str(), &dates, sessions, meta)?;
    tx.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES(?1, ?2)",
        params![BACKFILL_KEY, chrono::Utc::now().to_rfc3339()],
    )?;
    tx.commit()?;
    Ok(())
}

fn parse_provider(raw: &str) -> ProviderId {
    match raw {
        "cursor" => ProviderId::Cursor,
        "claude_code" => ProviderId::ClaudeCode,
        "claude_desktop" => ProviderId::ClaudeDesktop,
        "copilot" => ProviderId::Copilot,
        "grok_bot" => ProviderId::GrokBot,
        "codex" => ProviderId::Codex,
        _ => ProviderId::ClaudeCode,
    }
}

fn cutoff(days: u32) -> String {
    let days = days.clamp(7, MAX_HISTORY_DAYS);
    (chrono::Local::now().date_naive() - chrono::Duration::days(days as i64 - 1))
        .format("%Y-%m-%d")
        .to_string()
}

fn totals_from(row: &rusqlite::Row, first: usize) -> rusqlite::Result<TokenTotals> {
    let get =
        |i: usize| -> rusqlite::Result<u64> { Ok(row.get::<_, i64>(first + i)?.max(0) as u64) };
    Ok(TokenTotals {
        input: get(0)?,
        output: get(1)?,
        cache_read: get(2)?,
        cache_write: get(3)?,
    })
}

/// Last `days` local calendar days (oldest first), all providers mixed.
/// Missing days are omitted; the QML chart treats gaps as zero.
pub fn query_history(days: u32) -> anyhow::Result<Vec<HistoryPoint>> {
    let conn = connect()?;
    let mut stmt = conn.prepare(
        "SELECT provider, date, input, output, cache_read, cache_write
         FROM daily_tokens WHERE date >= ?1 ORDER BY date ASC",
    )?;
    let rows = stmt.query_map(params![cutoff(days)], |row| {
        let provider: String = row.get(0)?;
        let t = totals_from(row, 2)?;
        Ok(HistoryPoint {
            provider: parse_provider(&provider),
            date: row.get(1)?,
            input: t.input,
            output: t.output,
            cache_read: t.cache_read,
            cache_write: t.cache_write,
            total: t.total(),
        })
    })?;
    Ok(rows.flatten().collect())
}

/// Per-model days over the same range, each with its estimated cost.
pub fn query_models(days: u32) -> anyhow::Result<Vec<ModelDayPoint>> {
    let conn = connect()?;
    let mut stmt = conn.prepare(
        "SELECT provider, date, model, input, output, cache_read, cache_write
         FROM daily_model_tokens WHERE date >= ?1 ORDER BY date ASC, model ASC",
    )?;
    let rows = stmt.query_map(params![cutoff(days)], |row| {
        let provider: String = row.get(0)?;
        let model: String = row.get(2)?;
        let t = totals_from(row, 3)?;
        Ok(ModelDayPoint {
            provider: parse_provider(&provider),
            date: row.get(1)?,
            cost_usd: pricing::estimate_cost_usd(&model, &t),
            model,
            input: t.input,
            output: t.output,
            cache_read: t.cache_read,
            cache_write: t.cache_write,
            total: t.total(),
        })
    })?;
    Ok(rows.flatten().collect())
}

/// The range's dearest sessions, at most `limit`, each with its models
/// dearest first. A session without a name (its own transcript is gone) is
/// shown by its project or id.
pub fn query_sessions(days: u32, limit: usize) -> anyhow::Result<Vec<SessionCost>> {
    let conn = connect()?;
    sessions_since(&conn, &cutoff(days), limit)
}

fn sessions_since(
    conn: &Connection,
    first_date: &str,
    limit: usize,
) -> anyhow::Result<Vec<SessionCost>> {
    let mut stmt = conn.prepare(
        "SELECT s.provider, s.session_id, s.model,
                SUM(s.input), SUM(s.output), SUM(s.cache_read), SUM(s.cache_write), MAX(s.date),
                m.title, m.project, m.cwd, m.surface
         FROM session_model_tokens s
         LEFT JOIN session_meta m ON m.provider = s.provider AND m.session_id = s.session_id
         WHERE s.date >= ?1
         GROUP BY s.provider, s.session_id, s.model",
    )?;
    let rows = stmt.query_map(params![first_date], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            totals_from(row, 3)?,
            row.get::<_, String>(7)?,
            row.get::<_, Option<String>>(8)?,
            row.get::<_, Option<String>>(9)?,
            row.get::<_, Option<String>>(10)?,
            row.get::<_, Option<String>>(11)?,
        ))
    })?;

    let mut by_session: HashMap<(String, String), SessionCost> = HashMap::new();
    for (provider, id, model, t, last_date, title, project, cwd, surface) in rows.flatten() {
        let cost = pricing::estimate_cost_usd(&model, &t);
        let session = by_session
            .entry((provider.clone(), id.clone()))
            .or_insert_with(|| SessionCost {
                provider: parse_provider(&provider),
                title: title
                    .clone()
                    .or_else(|| project.clone())
                    .unwrap_or_else(|| id.clone()),
                id,
                project,
                cwd,
                surface,
                last_date: String::new(),
                input: 0,
                output: 0,
                cache_read: 0,
                cache_write: 0,
                total: 0,
                cost_usd: 0.0,
                models: Vec::new(),
            });
        if last_date > session.last_date {
            session.last_date = last_date;
        }
        session.input += t.input;
        session.output += t.output;
        session.cache_read += t.cache_read;
        session.cache_write += t.cache_write;
        session.total += t.total();
        session.cost_usd += cost;
        session.models.push(SessionModelCost {
            model,
            input: t.input,
            output: t.output,
            cache_read: t.cache_read,
            cache_write: t.cache_write,
            total: t.total(),
            cost_usd: cost,
        });
    }

    let mut sessions: Vec<SessionCost> = by_session.into_values().collect();
    for session in &mut sessions {
        session.models.sort_by(|a, b| {
            b.cost_usd
                .total_cmp(&a.cost_usd)
                .then(b.total.cmp(&a.total))
                .then(a.model.cmp(&b.model))
        });
    }
    sessions.sort_by(|a, b| {
        b.cost_usd
            .total_cmp(&a.cost_usd)
            .then(b.total.cmp(&a.total))
            .then(a.id.cmp(&b.id))
    });
    sessions.truncate(limit);
    Ok(sessions)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(date: &str, model: &str, output: u64) -> DayModelTokens {
        DayModelTokens {
            date: date.into(),
            model: model.into(),
            tokens: TokenTotals {
                input: 1,
                output,
                cache_read: 10,
                cache_write: 0,
            },
        }
    }

    fn memory() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        conn
    }

    /// The local day `back` days ago, so pruning never catches a test.
    fn ago(back: i64) -> String {
        (chrono::Local::now().date_naive() - chrono::Duration::days(back))
            .format("%Y-%m-%d")
            .to_string()
    }

    fn spent(session: &str, date: &str, model: &str, output: u64) -> SessionDayTokens {
        SessionDayTokens {
            session_id: session.into(),
            date: date.into(),
            model: model.into(),
            tokens: TokenTotals {
                input: 0,
                output,
                cache_read: 0,
                cache_write: 0,
            },
        }
    }

    fn named(session: &str, title: &str, hours_ago: i64) -> SessionMeta {
        SessionMeta {
            session_id: session.into(),
            title: title.into(),
            project: Some("omega-notch".into()),
            cwd: None,
            surface: Some("CLI".into()),
            updated_at: chrono::Utc::now() - chrono::Duration::hours(hours_ago),
        }
    }

    fn write_sessions(conn: &mut Connection, rows: &[SessionDayTokens], meta: &[SessionMeta]) {
        let mut dates: Vec<String> = rows.iter().map(|r| r.date.clone()).collect();
        dates.sort();
        dates.dedup();
        let tx = conn.transaction().unwrap();
        write_session_days(&tx, "claude_code", &dates, rows, meta).unwrap();
        tx.commit().unwrap();
    }

    #[test]
    fn sessions_come_dearest_first_with_their_models() {
        let mut conn = memory();
        let (d1, d2) = (ago(3), ago(1));
        write_sessions(
            &mut conn,
            &[
                spent("cheap", &d1, "Haiku 4.5", 1_000_000),
                spent("dear", &d1, "Opus 4.7", 1_000_000),
                spent("dear", &d2, "Opus 4.7", 1_000_000),
                spent("dear", &d2, "Haiku 4.5", 1_000_000),
            ],
            &[named("dear", "Big refactor", 1), named("cheap", "Typo", 2)],
        );
        let sessions = sessions_since(&conn, &ago(7), 10).unwrap();
        assert_eq!(sessions.len(), 2);
        let dear = &sessions[0];
        assert_eq!(dear.title, "Big refactor");
        assert_eq!(dear.last_date, d2);
        assert_eq!(dear.output, 3_000_000);
        assert_eq!(dear.models[0].model, "Opus 4.7");
        assert_eq!(dear.models[0].output, 2_000_000);
        assert_eq!(dear.models[1].model, "Haiku 4.5");
        let sum: f64 = dear.models.iter().map(|m| m.cost_usd).sum();
        assert!((dear.cost_usd - sum).abs() < 1e-9);
        assert_eq!(sessions[1].id, "cheap");

        // The range and the limit both cut.
        assert_eq!(sessions_since(&conn, &d2, 10).unwrap().len(), 1);
        assert_eq!(sessions_since(&conn, &ago(7), 1).unwrap()[0].id, "dear");
    }

    #[test]
    fn a_session_and_its_subagents_add_up() {
        let mut conn = memory();
        let d = ago(1);
        // The session's own transcript and a subagent's arrive apart.
        write_sessions(
            &mut conn,
            &[spent("s", &d, "Opus 4.7", 5), spent("s", &d, "Opus 4.7", 7)],
            &[],
        );
        let sessions = sessions_since(&conn, &ago(7), 10).unwrap();
        assert_eq!(sessions[0].output, 12);
        // No name stored: the id stands in.
        assert_eq!(sessions[0].title, "s");

        // A rescan of the same day replaces it rather than adding to it.
        write_sessions(&mut conn, &[spent("s", &d, "Opus 4.7", 20)], &[]);
        assert_eq!(sessions_since(&conn, &ago(7), 10).unwrap()[0].output, 20);
    }

    #[test]
    fn an_older_name_does_not_replace_a_newer_one() {
        let mut conn = memory();
        let d = ago(1);
        write_sessions(
            &mut conn,
            &[spent("s", &d, "Opus 4.7", 5)],
            &[named("s", "Renamed", 1)],
        );
        write_sessions(
            &mut conn,
            &[spent("s", &d, "Opus 4.7", 5)],
            &[named("s", "First prompt", 30)],
        );
        assert_eq!(
            sessions_since(&conn, &ago(7), 10).unwrap()[0].title,
            "Renamed"
        );
    }

    #[test]
    fn sessions_past_the_history_are_dropped_with_their_names() {
        let mut conn = memory();
        let old = ago(MAX_HISTORY_DAYS as i64 + 5);
        write_sessions(
            &mut conn,
            &[spent("old", &old, "Opus 4.7", 5)],
            &[named("old", "Old", 1)],
        );
        let count = |table: &str| -> i64 {
            conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(count("session_model_tokens"), 0);
        assert_eq!(count("session_meta"), 0);
    }

    #[test]
    fn cutoff_clamps() {
        assert_eq!(7u32.clamp(7, MAX_HISTORY_DAYS), 7);
        assert_eq!(1000u32.clamp(7, MAX_HISTORY_DAYS), MAX_HISTORY_DAYS);
    }

    #[test]
    fn rewriting_a_day_replaces_it() {
        let mut conn = memory();
        let dates = vec!["2026-10-01".to_string()];

        let tx = conn.transaction().unwrap();
        write_days(
            &tx,
            "claude_code",
            &dates,
            &[day("2026-10-01", "Opus", 5), day("2026-10-01", "Haiku", 2)],
        )
        .unwrap();
        tx.commit().unwrap();

        // Second pass: Haiku gone, Opus grew. Nothing may be counted twice.
        let tx = conn.transaction().unwrap();
        write_days(&tx, "claude_code", &dates, &[day("2026-10-01", "Opus", 9)]).unwrap();
        tx.commit().unwrap();

        let models: i64 = conn
            .query_row("SELECT COUNT(*) FROM daily_model_tokens", [], |r| r.get(0))
            .unwrap();
        let (output, cache_read): (i64, i64) = conn
            .query_row("SELECT output, cache_read FROM daily_tokens", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(models, 1);
        assert_eq!(output, 9);
        assert_eq!(cache_read, 10);
    }

    #[test]
    fn an_emptied_day_is_removed() {
        let mut conn = memory();
        let dates = vec!["2026-10-02".to_string()];
        let tx = conn.transaction().unwrap();
        write_days(&tx, "claude_code", &dates, &[day("2026-10-02", "Opus", 5)]).unwrap();
        write_days(&tx, "claude_code", &dates, &[]).unwrap();
        tx.commit().unwrap();
        let rows: i64 = conn
            .query_row("SELECT COUNT(*) FROM daily_tokens", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 0);
    }
}
