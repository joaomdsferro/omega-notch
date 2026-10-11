//! Recent chats and token totals, read from what the tools already keep on
//! disk. Nothing here talks to the network and nothing is written back.
//!
//! - Claude Code: `~/.claude/projects/**/*.jsonl` transcripts for titles and
//!   token usage, `~/.claude/sessions/*.json` for which chats are live.
//! - Cursor: the `composerHeaders` table of the editor's global state database.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::Value;
use walkdir::WalkDir;

use crate::config::AppConfig;
use crate::paths;
use crate::protocol::{
    Activity, ChatSummary, DayTokens, ModelTokens, ProviderId, SessionKind, TokenStats,
    TokenTotals,
};

/// Chats kept per provider in a snapshot.
const MAX_CHATS: usize = 8;
/// Days of token history, today included.
const HISTORY_DAYS: i64 = 7;
const TITLE_CHARS: usize = 90;

// ---------------------------------------------------------------------------
// Live Claude Code sessions
// ---------------------------------------------------------------------------

/// A running Claude Code process, as it describes itself in
/// `~/.claude/sessions/<pid>.json`.
#[derive(Debug, Clone)]
pub struct LiveSession {
    pub pid: u32,
    pub session_id: Option<String>,
    pub name: String,
    pub cwd: String,
    pub entrypoint: Option<String>,
    pub state: SessionKind,
    pub waiting_for: Option<String>,
    pub updated_at: DateTime<Utc>,
}

/// `None` when this Claude Code does not keep a session registry at all, so
/// callers can fall back to guessing from transcripts.
pub fn read_claude_sessions() -> Option<Vec<LiveSession>> {
    let dir = paths::claude_sessions();
    let entries = std::fs::read_dir(&dir).ok()?;
    let mut out = Vec::new();

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(raw) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let Some(pid) = value.get("pid").and_then(Value::as_u64) else {
            continue;
        };
        // A crashed process leaves its record behind.
        if !Path::new("/proc").join(pid.to_string()).exists() {
            continue;
        }
        let Some(cwd) = value.get("cwd").and_then(Value::as_str) else {
            continue;
        };

        let text = |key: &str| value.get(key).and_then(Value::as_str);
        let state = match (text("tempo"), text("status")) {
            (Some("blocked"), _) | (_, Some("waiting")) => SessionKind::WaitingYou,
            (Some("active"), _) | (_, Some("busy")) => SessionKind::Busy,
            _ => SessionKind::Idle,
        };
        let millis = ["statusUpdatedAt", "updatedAt", "startedAt"]
            .iter()
            .find_map(|key| value.get(*key).and_then(Value::as_i64));
        let updated_at = millis
            .and_then(|ms| Utc.timestamp_millis_opt(ms).single())
            .unwrap_or_else(Utc::now);

        out.push(LiveSession {
            pid: pid as u32,
            session_id: text("sessionId").map(str::to_string),
            name: text("name")
                .map(str::to_string)
                .unwrap_or_else(|| folder_name(cwd)),
            cwd: cwd.to_string(),
            entrypoint: text("entrypoint").map(str::to_string),
            state,
            waiting_for: text("waitingFor").or_else(|| text("needs")).map(str::to_string),
            updated_at,
        });
    }

    Some(out)
}

// ---------------------------------------------------------------------------
// Claude Code transcripts
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct RawLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    uuid: Option<String>,
    timestamp: Option<String>,
    cwd: Option<String>,
    entrypoint: Option<String>,
    #[serde(rename = "aiTitle")]
    ai_title: Option<String>,
    #[serde(rename = "customTitle")]
    custom_title: Option<String>,
    #[serde(rename = "lastPrompt")]
    last_prompt: Option<String>,
    #[serde(rename = "isMeta")]
    is_meta: Option<bool>,
    message: Option<RawMessage>,
}

#[derive(Deserialize)]
struct RawMessage {
    id: Option<String>,
    model: Option<String>,
    usage: Option<RawUsage>,
    content: Option<RawContent>,
}

#[derive(Deserialize)]
struct RawUsage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    cache_creation_input_tokens: Option<u64>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum RawContent {
    Text(String),
    Blocks(Vec<RawBlock>),
}

/// Only `text` is kept, so pasted images and tool output are skipped by the
/// parser instead of being copied into memory.
#[derive(Deserialize)]
struct RawBlock {
    #[serde(rename = "type")]
    kind: Option<String>,
    text: Option<String>,
}

struct Billed {
    day: NaiveDate,
    model: String,
    tokens: TokenTotals,
}

#[derive(Default)]
struct Transcript {
    /// Bytes already parsed; only complete lines are ever consumed.
    offset: u64,
    custom_title: Option<String>,
    ai_title: Option<String>,
    last_prompt: Option<String>,
    first_prompt: Option<String>,
    cwd: Option<String>,
    model: Option<String>,
    entrypoint: Option<String>,
    prompts: u32,
    context_tokens: u64,
    last_at: Option<DateTime<Utc>>,
    /// Latest usage per API message. One message spans several lines and its
    /// output count grows as it streams, so lines replace rather than add.
    billed: HashMap<String, Billed>,
    totals: TokenTotals,
    days: HashMap<NaiveDate, HashMap<String, TokenTotals>>,
}

impl Transcript {
    fn update(&mut self, path: &Path, size: u64) {
        if size < self.offset {
            // Rewritten from scratch (compaction, restore): start over.
            *self = Transcript::default();
        }
        if size == self.offset {
            return;
        }
        let Ok(mut file) = std::fs::File::open(path) else {
            return;
        };
        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            return;
        }
        let mut bytes = Vec::with_capacity((size - self.offset) as usize);
        if file.read_to_end(&mut bytes).is_err() {
            return;
        }
        // The writer may be mid-line; leave the tail for the next pass.
        let Some(end) = bytes.iter().rposition(|b| *b == b'\n') else {
            return;
        };
        for line in bytes[..end].split(|b| *b == b'\n') {
            if line.is_empty() {
                continue;
            }
            if let Ok(parsed) = serde_json::from_slice::<RawLine>(line) {
                self.ingest(parsed);
            }
        }
        self.offset += end as u64 + 1;
    }

    fn ingest(&mut self, line: RawLine) {
        let at = line
            .timestamp
            .as_deref()
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.with_timezone(&Utc));
        if let Some(at) = at {
            if self.last_at.is_none_or(|prev| at > prev) {
                self.last_at = Some(at);
            }
        }
        if line.cwd.is_some() {
            self.cwd = line.cwd;
        }
        if line.entrypoint.is_some() {
            self.entrypoint = line.entrypoint;
        }

        match line.kind.as_deref() {
            Some("ai-title") => self.ai_title = clean_title(line.ai_title.as_deref()),
            Some("custom-title") => {
                self.custom_title = clean_title(line.custom_title.as_deref())
            }
            Some("last-prompt") => self.last_prompt = clean_title(line.last_prompt.as_deref()),
            Some("user") if line.is_meta != Some(true) => {
                let text = match line.message.and_then(|m| m.content) {
                    Some(RawContent::Text(text)) => Some(text),
                    Some(RawContent::Blocks(blocks)) => blocks
                        .into_iter()
                        .filter(|b| b.kind.as_deref() == Some("text"))
                        .find_map(|b| b.text),
                    None => None,
                };
                // Tool results are user lines too; only typed prompts count.
                if let Some(title) = clean_title(text.as_deref()) {
                    self.prompts += 1;
                    if self.first_prompt.is_none() {
                        self.first_prompt = Some(title);
                    }
                }
            }
            Some("assistant") => {
                let Some(message) = line.message else { return };
                let Some(usage) = message.usage else { return };
                let model = message.model.unwrap_or_default();
                if model.is_empty() || model.starts_with('<') {
                    return;
                }
                let tokens = TokenTotals {
                    input: usage.input_tokens.unwrap_or(0),
                    output: usage.output_tokens.unwrap_or(0),
                    cache_read: usage.cache_read_input_tokens.unwrap_or(0),
                    cache_write: usage.cache_creation_input_tokens.unwrap_or(0),
                };
                let Some(key) = message.id.or(line.uuid) else { return };
                let day = at.unwrap_or_else(Utc::now).with_timezone(&Local).date_naive();

                if let Some(old) = self.billed.remove(&key) {
                    self.totals.sub(&old.tokens);
                    if let Some(models) = self.days.get_mut(&old.day) {
                        if let Some(bucket) = models.get_mut(&old.model) {
                            bucket.sub(&old.tokens);
                        }
                    }
                }
                self.totals.add(&tokens);
                self.days
                    .entry(day)
                    .or_default()
                    .entry(model.clone())
                    .or_default()
                    .add(&tokens);
                self.context_tokens = tokens.input + tokens.cache_read + tokens.cache_write;
                self.model = Some(model.clone());
                self.billed.insert(key, Billed { day, model, tokens });
            }
            _ => {}
        }
    }

    fn title(&self) -> Option<String> {
        self.custom_title
            .clone()
            .or_else(|| self.ai_title.clone())
            .or_else(|| self.last_prompt.clone())
            .or_else(|| self.first_prompt.clone())
    }
}

struct Candidate {
    path: PathBuf,
    modified: SystemTime,
    size: u64,
    /// `projects/<project>/<session>.jsonl`; deeper files are subagents.
    top_level: bool,
}

/// Incremental reader state. Transcripts only ever grow, so each scan parses
/// just the bytes appended since the previous one.
#[derive(Default)]
pub struct ActivityIndex {
    claude: HashMap<PathBuf, Transcript>,
}

impl ActivityIndex {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn scan(&mut self, config: &AppConfig) -> Activity {
        let mut activity = Activity::default();

        if config.provider_enabled(ProviderId::ClaudeCode) {
            let (chats, tokens) = self.scan_claude();
            activity.chats.extend(chats);
            activity.tokens.push(tokens);
        } else {
            self.claude.clear();
        }

        if config.provider_enabled(ProviderId::Cursor) {
            activity.chats.extend(cursor_chats());
        }

        activity
    }

    fn scan_claude(&mut self) -> (Vec<ChatSummary>, TokenStats) {
        let today = Local::now().date_naive();
        let first_day = today - Duration::days(HISTORY_DAYS - 1);
        let window_start: SystemTime = first_day
            .and_hms_opt(0, 0, 0)
            .and_then(|t| Local.from_local_datetime(&t).earliest())
            .map(SystemTime::from)
            .unwrap_or(SystemTime::UNIX_EPOCH);

        let mut candidates = Vec::new();
        let root = paths::claude_projects();
        if root.exists() {
            for entry in WalkDir::new(&root).max_depth(4).into_iter().flatten() {
                if !entry.file_type().is_file()
                    || entry.path().extension().and_then(|s| s.to_str()) != Some("jsonl")
                {
                    continue;
                }
                let Ok(meta) = entry.metadata() else { continue };
                let Ok(modified) = meta.modified() else { continue };
                candidates.push(Candidate {
                    path: entry.path().to_path_buf(),
                    modified,
                    size: meta.len(),
                    top_level: entry.depth() == 2,
                });
            }
        }
        candidates.sort_by(|a, b| b.modified.cmp(&a.modified));

        // Parse what feeds the token history, plus the newest chats even when
        // they are older than that.
        let mut listed = 0usize;
        let mut keep: HashSet<PathBuf> = HashSet::new();
        let mut recent: Vec<&Candidate> = Vec::new();
        for candidate in &candidates {
            let is_recent_chat = candidate.top_level && listed < MAX_CHATS;
            if is_recent_chat {
                listed += 1;
                recent.push(candidate);
            }
            if is_recent_chat || candidate.modified >= window_start {
                self.claude
                    .entry(candidate.path.clone())
                    .or_default()
                    .update(&candidate.path, candidate.size);
                keep.insert(candidate.path.clone());
            }
        }
        self.claude.retain(|path, _| keep.contains(path));

        // Tokens.
        let mut per_day: HashMap<NaiveDate, TokenTotals> = HashMap::new();
        let mut models_today: HashMap<&str, u64> = HashMap::new();
        for transcript in self.claude.values() {
            for (day, models) in &transcript.days {
                if *day < first_day || *day > today {
                    continue;
                }
                for (model, tokens) in models {
                    per_day.entry(*day).or_default().add(tokens);
                    if *day == today {
                        *models_today.entry(model.as_str()).or_default() += tokens.total();
                    }
                }
            }
        }
        let mut week = TokenTotals::default();
        let mut daily = Vec::with_capacity(HISTORY_DAYS as usize);
        for offset in 0..HISTORY_DAYS {
            let day = first_day + Duration::days(offset);
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
            .map(|(model, total)| ModelTokens {
                model: pretty_model(model),
                total,
            })
            .collect();
        models_today.sort_by(|a, b| b.total.cmp(&a.total).then(a.model.cmp(&b.model)));

        let stats = TokenStats {
            provider: ProviderId::ClaudeCode,
            today: per_day.get(&today).copied().unwrap_or_default(),
            week,
            daily,
            models_today,
        };

        // Chats.
        let live: HashMap<String, LiveSession> = read_claude_sessions()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|s| s.session_id.clone().map(|id| (id, s)))
            .collect();

        let mut chats = Vec::new();
        for candidate in recent {
            let Some(transcript) = self.claude.get(&candidate.path) else {
                continue;
            };
            let Some(id) = candidate.path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let session = live.get(id);
            let cwd = transcript
                .cwd
                .clone()
                .or_else(|| session.map(|s| s.cwd.clone()));
            let project = cwd.as_deref().map(folder_name);
            // A window opened and closed without a prompt is not a chat.
            if transcript.prompts == 0 && transcript.totals.total() == 0 {
                continue;
            }
            let Some(title) = transcript.title().or_else(|| project.clone()) else {
                continue;
            };
            let entrypoint = transcript
                .entrypoint
                .as_deref()
                .or_else(|| session.and_then(|s| s.entrypoint.as_deref()));

            chats.push(ChatSummary {
                provider: ProviderId::ClaudeCode,
                id: id.to_string(),
                title,
                project,
                cwd,
                model: transcript.model.as_deref().map(pretty_model),
                surface: entrypoint.and_then(claude_surface).map(str::to_string),
                state: session.map_or(SessionKind::Idle, |s| s.state),
                live: session.is_some(),
                updated_at: transcript
                    .last_at
                    .unwrap_or_else(|| DateTime::<Utc>::from(candidate.modified)),
                messages: transcript.prompts,
                tokens: Some(transcript.totals),
                context_tokens: (transcript.context_tokens > 0)
                    .then_some(transcript.context_tokens),
                context_pct: None,
                lines_added: None,
                lines_removed: None,
            });
        }
        chats.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));

        (chats, stats)
    }
}

fn claude_surface(entrypoint: &str) -> Option<&'static str> {
    match entrypoint {
        "cli" => Some("CLI"),
        "claude-vscode" => Some("VS Code"),
        "claude-desktop" | "claude-desktop-3p" => Some("Desktop"),
        "claude-jetbrains" => Some("JetBrains"),
        other if other.starts_with("sdk") => Some("SDK"),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

fn cursor_chats() -> Vec<ChatSummary> {
    let path = paths::cursor_state_db();
    if !path.exists() {
        return Vec::new();
    }
    let uri = format!("file:{}?mode=ro", path.display());
    let Ok(conn) = Connection::open_with_flags(
        &uri,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    ) else {
        return Vec::new();
    };
    let _ = conn.busy_timeout(std::time::Duration::from_millis(400));

    // Older Cursor builds have no such table; that is simply "no chats".
    let Ok(mut statement) = conn.prepare(
        "SELECT composerId, lastUpdatedAt, createdAt, value FROM composerHeaders \
         WHERE isSubagent = 0 AND isArchived = 0 ORDER BY recency DESC LIMIT ?1",
    ) else {
        return Vec::new();
    };
    let rows = statement.query_map([(MAX_CHATS * 2) as i64], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<i64>>(1)?,
            row.get::<_, Option<i64>>(2)?,
            row.get::<_, Option<String>>(3)?,
        ))
    });
    let Ok(rows) = rows else {
        return Vec::new();
    };

    let mut chats = Vec::new();
    for (id, updated, created, value) in rows.flatten() {
        let head: Value = value
            .as_deref()
            .and_then(|raw| serde_json::from_str(raw).ok())
            .unwrap_or(Value::Null);
        if head.get("isDraft").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(title) = clean_title(head.get("name").and_then(Value::as_str)) else {
            continue;
        };
        let Some(updated_at) = updated
            .or(created)
            .and_then(|ms| Utc.timestamp_millis_opt(ms).single())
        else {
            continue;
        };
        let cwd = head
            .pointer("/workspaceIdentifier/uri/fsPath")
            .and_then(Value::as_str)
            .map(str::to_string);
        let waiting = head
            .get("hasBlockingPendingActions")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        chats.push(ChatSummary {
            provider: ProviderId::Cursor,
            id,
            title,
            project: cwd.as_deref().map(folder_name),
            cwd,
            model: None,
            surface: head
                .get("unifiedMode")
                .and_then(Value::as_str)
                .map(capitalize),
            state: if waiting {
                SessionKind::WaitingYou
            } else {
                SessionKind::Idle
            },
            live: waiting,
            updated_at,
            messages: 0,
            tokens: None,
            context_tokens: None,
            context_pct: head
                .get("contextUsagePercent")
                .and_then(Value::as_f64)
                .map(|p| p.clamp(0.0, 100.0)),
            lines_added: head.get("totalLinesAdded").and_then(Value::as_u64),
            lines_removed: head.get("totalLinesRemoved").and_then(Value::as_u64),
        });
        if chats.len() == MAX_CHATS {
            break;
        }
    }
    chats
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

pub(crate) fn folder_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(path)
        .to_string()
}

/// One line, trimmed and bounded. Harness-injected text (`<command-name>`,
/// `<system-reminder>`…) is not something the user typed, so it is no title.
fn clean_title(raw: Option<&str>) -> Option<String> {
    let text = raw?.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.is_empty() || text.starts_with('<') {
        return None;
    }
    if text.chars().count() <= TITLE_CHARS {
        return Some(text);
    }
    let mut short: String = text.chars().take(TITLE_CHARS - 1).collect();
    short.push('…');
    Some(short)
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// `claude-opus-5-5` → `Opus 5.5`, `claude-haiku-4-5-20251001` → `Haiku 4.5`.
pub fn pretty_model(id: &str) -> String {
    let mut words: Vec<String> = Vec::new();
    let mut version: Vec<&str> = Vec::new();
    let flush = |version: &mut Vec<&str>, words: &mut Vec<String>| {
        if !version.is_empty() {
            words.push(version.join("."));
            version.clear();
        }
    };

    for part in id.split('-') {
        if part.is_empty() || part == "claude" {
            continue;
        }
        let numeric = part.chars().all(|c| c.is_ascii_digit());
        if numeric && part.len() >= 8 {
            continue; // release date
        }
        if numeric {
            version.push(part);
        } else {
            flush(&mut version, &mut words);
            words.push(capitalize(part));
        }
    }
    flush(&mut version, &mut words);

    if words.is_empty() {
        id.to_string()
    } else {
        words.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_names() {
        assert_eq!(pretty_model("claude-opus-5-5"), "Opus 5.5");
        assert_eq!(pretty_model("claude-haiku-4-5-20251001"), "Haiku 4.5");
        assert_eq!(pretty_model("claude-3-5-sonnet-20241022"), "3.5 Sonnet");
        assert_eq!(pretty_model("gpt"), "Gpt");
    }

    #[test]
    fn titles() {
        assert_eq!(clean_title(Some("  fix\n the  bug ")).as_deref(), Some("fix the bug"));
        assert_eq!(clean_title(Some("<command-name>/clear</command-name>")), None);
        assert_eq!(clean_title(Some("   ")), None);
        let long = "a".repeat(200);
        assert_eq!(clean_title(Some(&long)).unwrap().chars().count(), TITLE_CHARS);
    }

    fn line(json: &str) -> RawLine {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn streamed_message_is_billed_once() {
        let mut t = Transcript::default();
        t.ingest(line(
            r#"{"type":"user","timestamp":"2026-09-30T10:00:00Z","cwd":"/w/app",
                "message":{"content":[{"type":"image","source":{"data":"xx"}},{"type":"text","text":"hello there"}]}}"#,
        ));
        t.ingest(line(
            r#"{"type":"user","timestamp":"2026-09-30T10:00:01Z",
                "message":{"content":[{"type":"tool_result","content":"out"}]}}"#,
        ));
        for output in [10, 250] {
            t.ingest(line(&format!(
                r#"{{"type":"assistant","timestamp":"2026-09-30T10:00:05Z","message":{{"id":"m1","model":"claude-opus-5-5",
                    "usage":{{"input_tokens":2,"output_tokens":{output},"cache_read_input_tokens":1000,"cache_creation_input_tokens":500}}}}}}"#
            )));
        }
        t.ingest(line(r#"{"type":"ai-title","aiTitle":"Greeting"}"#));

        assert_eq!(t.prompts, 1);
        assert_eq!(t.totals.output, 250);
        assert_eq!(t.totals.total(), 1752);
        assert_eq!(t.context_tokens, 1502);
        assert_eq!(t.title().as_deref(), Some("Greeting"));
        let summed: u64 = t
            .days
            .values()
            .flat_map(|m| m.values())
            .map(TokenTotals::total)
            .sum();
        assert_eq!(summed, 1752);
    }
}
