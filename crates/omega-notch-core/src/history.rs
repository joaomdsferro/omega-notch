//! Persistent daily token totals for the dashboard.
//!
//! The live scan in [`crate::chats`] only keeps the last seven days in
//! memory. The dashboard wants 30–90 day trends without rescanning every
//! transcript on each open, so every activity refresh rewrites the days it
//! covers here. Two tables: one row per tool and day (`daily_tokens`), and
//! one per tool, day and model (`daily_model_tokens`), both split by kind.
//! SQLite via `rusqlite` (bundled) keeps it dependency-free.

use std::collections::HashMap;
use std::path::PathBuf;

use rusqlite::{params, Connection, OptionalExtension};

use crate::paths;
use crate::pricing;
use crate::protocol::{
    DayModelTokens, HistoryPoint, ModelDayPoint, ProviderId, TokenStats, TokenTotals,
};

/// History is capped; the dashboard never asks for more than this.
pub const MAX_HISTORY_DAYS: u32 = 90;

/// Bumped when the backfill learns something new, so it runs once more.
const BACKFILL_KEY: &str = "claude_backfill_v1";

pub fn history_db_path() -> PathBuf {
    paths::app_data_dir().join("history.db")
}

fn connect() -> anyhow::Result<Connection> {
    let dir = paths::app_data_dir();
    std::fs::create_dir_all(&dir)?;
    let conn = Connection::open(history_db_path())?;
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
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );",
    )?;
    Ok(conn)
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
        write_days(&tx, stats.provider.as_str(), &dates, &stats.days_by_model)?;
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
pub fn record_backfill(provider: ProviderId, rows: &[DayModelTokens]) -> anyhow::Result<()> {
    let mut dates: Vec<String> = rows.iter().map(|r| r.date.clone()).collect();
    dates.dedup();
    let mut conn = connect()?;
    let tx = conn.transaction()?;
    write_days(&tx, provider.as_str(), &dates, rows)?;
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
        conn.execute_batch(
            "CREATE TABLE daily_tokens(provider TEXT, date TEXT, input INTEGER, output INTEGER,
                cache_read INTEGER, cache_write INTEGER, PRIMARY KEY(provider, date));
             CREATE TABLE daily_model_tokens(provider TEXT, date TEXT, model TEXT, input INTEGER,
                output INTEGER, cache_read INTEGER, cache_write INTEGER,
                PRIMARY KEY(provider, date, model));",
        )
        .unwrap();
        conn
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
