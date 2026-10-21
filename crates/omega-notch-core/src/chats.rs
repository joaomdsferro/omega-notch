//! Recent chats and token totals, read from what the tools already keep on
//! disk. Nothing here talks to the network and nothing is written back.
//!
//! - Claude Code: `~/.claude/projects/**/*.jsonl` transcripts for titles and
//!   token usage, `~/.claude/sessions/*.json` for which chats are live.
//! - Cursor: the `composerHeaders` table of the editor's global state database,
//!   with `composerData:<id>` for the model, live flags, and context size.
//!   Token totals come from Cursor's usage-events API (see `providers::cursor`).
//! - GitHub Copilot Chat: VS Code `workspaceStorage/*/chatSessions/*.jsonl`
//!   patch logs (titles, model, pending confirmations).
//! - Codex: `~/.codex/session_index.jsonl` for titles, rollout `session_meta`
//!   under `~/.codex/sessions` for cwd and surface, and early `turn_context`
//!   for the model.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::Value;
use walkdir::WalkDir;

use crate::config::AppConfig;
use crate::memo::FileMemo;
use crate::paths;
use crate::platform;
use crate::protocol::{
    Activity, ChatSummary, DayModelTokens, DayTokens, ModelTokens, ProviderId, SessionDayTokens,
    SessionKind, SessionMeta, TokenStats, TokenTotals,
};
use crate::providers::profiles;

/// Chats kept per provider in a snapshot.
pub(crate) const MAX_CHATS: usize = 8;
/// Days of token history, today included.
pub const HISTORY_DAYS: i64 = 7;
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
pub fn read_claude_sessions(dir: &Path) -> Option<Vec<LiveSession>> {
    let entries = std::fs::read_dir(dir).ok()?;
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
        if !u32::try_from(pid).is_ok_and(platform::is_alive) {
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
            waiting_for: text("waitingFor")
                .or_else(|| text("needs"))
                .map(str::to_string),
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
    /// A slash command with arguments, for a chat with no typed prompt.
    command_prompt: Option<String>,
    cwd: Option<String>,
    model: Option<String>,
    entrypoint: Option<String>,
    prompts: u32,
    context_tokens: u64,
    last_at: Option<DateTime<Utc>>,
    /// The latest typed prompt and the latest reply, for telling a chat that
    /// finished since you last wrote in it.
    prompted_at: Option<DateTime<Utc>>,
    replied_at: Option<DateTime<Utc>>,
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
        // Where the session started: the project, even after a `cd` into one
        // of its folders.
        if self.cwd.is_none() {
            self.cwd = line.cwd;
        }
        if line.entrypoint.is_some() {
            self.entrypoint = line.entrypoint;
        }

        match line.kind.as_deref() {
            Some("ai-title") => self.ai_title = clean_title(line.ai_title.as_deref()),
            Some("custom-title") => self.custom_title = clean_title(line.custom_title.as_deref()),
            Some("last-prompt") => self.last_prompt = clean_title(line.last_prompt.as_deref()),
            Some("user") if line.is_meta != Some(true) => {
                let texts: Vec<String> = match line.message.and_then(|m| m.content) {
                    Some(RawContent::Text(text)) => vec![text],
                    Some(RawContent::Blocks(blocks)) => blocks
                        .into_iter()
                        .filter(|b| b.kind.as_deref() == Some("text"))
                        .filter_map(|b| b.text)
                        .collect(),
                    None => Vec::new(),
                };
                // Tool results are user lines too; only typed prompts count.
                // The editor's context comes first in its own block, so the
                // prompt is the first block that reads as one.
                let typed = texts
                    .iter()
                    .any(|t| clean_title(Some(t)).is_some() || command_title(t).is_some());
                if typed {
                    self.prompted_at = latest(self.prompted_at, at);
                }
                if let Some(title) = texts.iter().find_map(|t| clean_title(Some(t))) {
                    self.prompts += 1;
                    if self.first_prompt.is_none() {
                        self.first_prompt = Some(title);
                    }
                } else if let Some(title) = texts.iter().find_map(|t| command_title(t)) {
                    self.prompts += 1;
                    if self.command_prompt.is_none() {
                        self.command_prompt = Some(title);
                    }
                }
            }
            Some("assistant") => {
                let Some(message) = line.message else { return };
                // Only words to read: a turn that is all tool calls is not a reply.
                let says = match &message.content {
                    Some(RawContent::Text(text)) => !text.trim().is_empty(),
                    Some(RawContent::Blocks(blocks)) => blocks.iter().any(|b| {
                        b.kind.as_deref() == Some("text")
                            && b.text.as_deref().is_some_and(|t| !t.trim().is_empty())
                    }),
                    None => false,
                };
                if says {
                    self.replied_at = latest(self.replied_at, at);
                }
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
                let Some(key) = message.id.or(line.uuid) else {
                    return;
                };
                let day = at
                    .unwrap_or_else(Utc::now)
                    .with_timezone(&Local)
                    .date_naive();

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
            .or_else(|| self.command_prompt.clone())
    }

    /// How the dashboard names this session; `None` for a window opened
    /// and closed without a prompt.
    fn meta(&self, session_id: &str) -> Option<SessionMeta> {
        if self.prompts == 0 && self.totals.total() == 0 {
            return None;
        }
        let project = self.cwd.as_deref().map(folder_name);
        Some(SessionMeta {
            session_id: session_id.to_string(),
            title: self.title().or_else(|| project.clone())?,
            project,
            cwd: self.cwd.clone(),
            surface: self
                .entrypoint
                .as_deref()
                .and_then(claude_surface)
                .map(str::to_string),
            updated_at: self.last_at?,
        })
    }
}

/// The session a transcript belongs to: its own name for
/// `projects/<project>/<session>.jsonl`, and the session that ran it for a
/// subagent under `projects/<project>/<session>/…`. The flag says which.
fn claude_session_id(root: &Path, path: &Path) -> Option<(String, bool)> {
    let parts: Vec<&str> = path
        .strip_prefix(root)
        .ok()?
        .iter()
        .filter_map(|c| c.to_str())
        .collect();
    match parts.as_slice() {
        [_, file] => Some((Path::new(file).file_stem()?.to_str()?.to_string(), true)),
        [_, session, _, ..] => Some((session.to_string(), false)),
        _ => None,
    }
}

/// Per-session rows in `first_day..=last_day` from every transcript given,
/// with the names of the sessions whose own transcript is among them. Both
/// sorted, so two scans of the same files compare equal.
fn session_rows<'a>(
    root: &Path,
    transcripts: impl Iterator<Item = (&'a PathBuf, &'a Transcript)>,
    first_day: NaiveDate,
    last_day: NaiveDate,
) -> (Vec<SessionDayTokens>, Vec<SessionMeta>) {
    let mut merged: HashMap<(String, NaiveDate, String), TokenTotals> = HashMap::new();
    let mut meta = Vec::new();
    for (path, transcript) in transcripts {
        let Some((session, own)) = claude_session_id(root, path) else {
            continue;
        };
        for (day, models) in &transcript.days {
            if *day < first_day || *day > last_day {
                continue;
            }
            for (model, tokens) in models {
                merged
                    .entry((session.clone(), *day, pretty_model(model)))
                    .or_default()
                    .add(tokens);
            }
        }
        if own {
            meta.extend(transcript.meta(&session));
        }
    }
    let mut rows: Vec<SessionDayTokens> = merged
        .into_iter()
        .filter(|(_, tokens)| tokens.total() > 0)
        .map(|((session_id, day, model), tokens)| SessionDayTokens {
            session_id,
            date: day.format("%Y-%m-%d").to_string(),
            model,
            tokens,
        })
        .collect();
    rows.sort_by(|a, b| {
        (&a.session_id, &a.date, &a.model).cmp(&(&b.session_id, &b.date, &b.model))
    });
    meta.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    (rows, meta)
}

fn latest(current: Option<DateTime<Utc>>, at: Option<DateTime<Utc>>) -> Option<DateTime<Utc>> {
    match (current, at) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    }
}

/// Folds raw model ids into display names (two ids can share one) and drops
/// empty buckets, sorted by day then model so the output is stable.
fn day_model_rows(raw: HashMap<(NaiveDate, &str), TokenTotals>) -> Vec<DayModelTokens> {
    let mut merged: HashMap<(NaiveDate, String), TokenTotals> = HashMap::new();
    for ((day, model), tokens) in raw {
        merged
            .entry((day, pretty_model(model)))
            .or_default()
            .add(&tokens);
    }
    let mut rows: Vec<DayModelTokens> = merged
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
}

/// What the one-off backfill found: days by model, and by session.
#[derive(Debug, Default)]
pub struct Backfill {
    pub days: Vec<DayModelTokens>,
    pub sessions: Vec<SessionDayTokens>,
    pub meta: Vec<SessionMeta>,
}

/// Every Claude Code day still on disk from `first_day` up to, but not
/// including, `before`, split by model and by session. A one-off pass for the
/// dashboard history: each transcript is parsed and dropped, nothing is kept.
pub fn backfill_claude(dir: &Path, first_day: NaiveDate, before: NaiveDate) -> Backfill {
    let start: SystemTime = first_day
        .and_hms_opt(0, 0, 0)
        .and_then(|t| Local.from_local_datetime(&t).earliest())
        .map(SystemTime::from)
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let mut totals: HashMap<(NaiveDate, String), TokenTotals> = HashMap::new();
    let mut found = Backfill::default();
    let root = dir.join("projects");
    if !root.exists() {
        return found;
    }
    let last_day = before.pred_opt().unwrap_or(before);
    for entry in WalkDir::new(&root).max_depth(4).into_iter().flatten() {
        if !entry.file_type().is_file()
            || entry.path().extension().and_then(|s| s.to_str()) != Some("jsonl")
        {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        // A transcript last written before the range holds nothing in it.
        if meta.modified().map_or(true, |m| m < start) {
            continue;
        }
        let mut transcript = Transcript::default();
        transcript.update(entry.path(), meta.len());
        let path = entry.path().to_path_buf();
        let (rows, names) = session_rows(
            &root,
            std::iter::once((&path, &transcript)),
            first_day,
            last_day,
        );
        found.sessions.extend(rows);
        found.meta.extend(names);
        for (day, models) in transcript.days {
            if day < first_day || day >= before {
                continue;
            }
            for (model, tokens) in models {
                totals.entry((day, model)).or_default().add(&tokens);
            }
        }
    }
    found.days = day_model_rows(
        totals
            .iter()
            .map(|((d, m), t)| ((*d, m.as_str()), *t))
            .collect(),
    );
    found
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
    /// Copilot sessions are rewritten whole, so they are re-read only when
    /// they change.
    copilot: FileMemo<Option<ChatSummary>>,
}

impl ActivityIndex {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn scan(&mut self, config: &AppConfig) -> Activity {
        let mut activity = Activity::default();

        if config.provider_enabled(&ProviderId::ClaudeCode) {
            let mut roots = Vec::new();
            for profile in profiles::claude_profiles() {
                if !config.provider_enabled(&profile.id) {
                    continue;
                }
                roots.push(profile.dir.join("projects"));
                let (chats, tokens) = self.scan_claude(&profile.dir, &profile.id);
                activity.chats.extend(chats);
                activity.tokens.push(tokens);
            }
            // Forget transcripts of a profile that was switched off or whose
            // directory went away, so its numbers stop counting.
            self.claude
                .retain(|path, _| roots.iter().any(|root| path.starts_with(root)));
        } else {
            self.claude.clear();
        }

        if config.provider_enabled(&ProviderId::Cursor) {
            activity.chats.extend(cursor_chats());
        }

        if config.provider_enabled(&ProviderId::Copilot) {
            activity.chats.extend(copilot_chats(&mut self.copilot));
        } else {
            self.copilot = FileMemo::default();
        }

        if config.provider_enabled(&ProviderId::Codex) {
            for profile in profiles::codex_profiles() {
                if !config.provider_enabled(&profile.id) {
                    continue;
                }
                activity.chats.extend(codex_chats_at(
                    &profile.dir.join("session_index.jsonl"),
                    &profile.dir.join("sessions"),
                    &profile.id,
                ));
            }
        }

        if config.provider_enabled(&ProviderId::OpenCode) {
            let (chats, tokens) = crate::opencode::activity();
            activity.chats.extend(chats);
            activity.tokens.push(tokens);
        }

        if config.provider_enabled(&ProviderId::GrokBot) {
            activity.chats.extend(crate::grok_bot::bots());
        }

        activity
    }

    fn scan_claude(&mut self, dir: &Path, provider: &ProviderId) -> (Vec<ChatSummary>, TokenStats) {
        let today = Local::now().date_naive();
        let first_day = today - Duration::days(HISTORY_DAYS - 1);
        let window_start: SystemTime = first_day
            .and_hms_opt(0, 0, 0)
            .and_then(|t| Local.from_local_datetime(&t).earliest())
            .map(SystemTime::from)
            .unwrap_or(SystemTime::UNIX_EPOCH);

        let mut candidates = Vec::new();
        let root = dir.join("projects");
        if root.exists() {
            for entry in WalkDir::new(&root).max_depth(4).into_iter().flatten() {
                if !entry.file_type().is_file()
                    || entry.path().extension().and_then(|s| s.to_str()) != Some("jsonl")
                {
                    continue;
                }
                let Ok(meta) = entry.metadata() else { continue };
                let Ok(modified) = meta.modified() else {
                    continue;
                };
                candidates.push(Candidate {
                    path: entry.path().to_path_buf(),
                    modified,
                    size: meta.len(),
                    top_level: entry.depth() == 2,
                });
            }
        }
        candidates.sort_by_key(|c| std::cmp::Reverse(c.modified));

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
        // Only this profile's transcripts: the map is shared by every profile.
        self.claude
            .retain(|path, _| !path.starts_with(&root) || keep.contains(path));

        // Tokens.
        let mut per_day: HashMap<NaiveDate, TokenTotals> = HashMap::new();
        let mut models_today: HashMap<&str, u64> = HashMap::new();
        let mut per_day_model: HashMap<(NaiveDate, &str), TokenTotals> = HashMap::new();
        for (_, transcript) in self
            .claude
            .iter()
            .filter(|(path, _)| path.starts_with(&root))
        {
            for (day, models) in &transcript.days {
                if *day < first_day || *day > today {
                    continue;
                }
                for (model, tokens) in models {
                    per_day.entry(*day).or_default().add(tokens);
                    per_day_model
                        .entry((*day, model.as_str()))
                        .or_default()
                        .add(tokens);
                    if *day == today {
                        *models_today.entry(model.as_str()).or_default() += tokens.total();
                    }
                }
            }
        }
        let days_by_model = day_model_rows(per_day_model);
        let (session_days, session_meta) =
            session_rows(&root, self.claude.iter(), first_day, today);
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
            provider: provider.clone(),
            today: per_day.get(&today).copied().unwrap_or_default(),
            week,
            daily,
            models_today,
            days_by_model,
            session_days,
            session_meta,
        };

        // Chats.
        let live: HashMap<String, LiveSession> = read_claude_sessions(&dir.join("sessions"))
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
                provider: provider.clone(),
                id: id.to_string(),
                title,
                project,
                cwd,
                model: transcript.model.as_deref().map(pretty_model),
                surface: entrypoint.and_then(claude_surface).map(str::to_string),
                preview: None,
                avatar_shape: None,
                avatar_color: None,
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
                unread: false,
                prompted_at: transcript.prompted_at,
                replied_at: transcript.replied_at,
            });
        }
        chats.sort_by_key(|c| std::cmp::Reverse(c.updated_at));

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
    let Some(conn) = open_cursor_state_db() else {
        return Vec::new();
    };

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
        let data = cursor_composer_data(&conn, &id);
        let (state, _) = cursor_composer_kind(&head, data.as_ref(), updated.or(created));
        let model = data
            .as_ref()
            .and_then(cursor_model_from_data)
            .or_else(|| cursor_composer_model(&conn, &id));
        let context_tokens = data
            .as_ref()
            .and_then(|value| value.pointer("/promptTokenBreakdown/totalUsedTokens"))
            .and_then(Value::as_u64)
            .filter(|n| *n > 0);
        let context_pct = head
            .get("contextUsagePercent")
            .or_else(|| data.as_ref().and_then(|v| v.get("contextUsagePercent")))
            .and_then(Value::as_f64)
            .map(|p| p.clamp(0.0, 100.0));

        chats.push(ChatSummary {
            provider: ProviderId::Cursor,
            id,
            title,
            project: cwd.as_deref().map(folder_name),
            cwd,
            model,
            surface: head
                .get("unifiedMode")
                .and_then(Value::as_str)
                .map(capitalize),
            preview: None,
            avatar_shape: None,
            avatar_color: None,
            state,
            live: state != SessionKind::Idle,
            updated_at,
            messages: 0,
            tokens: None,
            context_tokens,
            context_pct,
            lines_added: head.get("totalLinesAdded").and_then(Value::as_u64),
            lines_removed: head.get("totalLinesRemoved").and_then(Value::as_u64),
            // Cursor keeps no time for its last reply apart from your edits.
            unread: false,
            prompted_at: None,
            replied_at: None,
        });
        if chats.len() == MAX_CHATS {
            break;
        }
    }
    chats
}

/// One Cursor composer as the session watcher sees it: id, live kind, and a
/// label for alerts when that composer finishes or asks.
#[derive(Debug, Clone)]
pub struct CursorComposerSession {
    pub id: String,
    pub kind: SessionKind,
    /// The composer cleared its live flags itself. Idle from a sticky
    /// `unfinishedRunAt` after the grace window is not a finish to announce.
    pub finished: bool,
    pub label: String,
}

/// Every non-draft composer in Cursor's state DB, newest first. Used both for
/// the ring's aggregate state and for announcing each chat on its own.
pub fn cursor_composer_sessions() -> Vec<CursorComposerSession> {
    let Some(conn) = open_cursor_state_db() else {
        return Vec::new();
    };
    let Ok(mut statement) = conn.prepare(
        "SELECT composerId, lastUpdatedAt, value FROM composerHeaders \
         WHERE isSubagent = 0 AND isArchived = 0 ORDER BY recency DESC LIMIT 40",
    ) else {
        return Vec::new();
    };
    let Ok(rows) = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<i64>>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    }) else {
        return Vec::new();
    };

    let mut out = Vec::new();
    for (id, updated, value) in rows.flatten() {
        let head: Value = value
            .as_deref()
            .and_then(|raw| serde_json::from_str(raw).ok())
            .unwrap_or(Value::Null);
        if head.get("isDraft").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let data = cursor_composer_data(&conn, &id);
        let (kind, finished) = cursor_composer_kind(&head, data.as_ref(), updated);
        let label =
            clean_title(head.get("name").and_then(Value::as_str)).unwrap_or_else(|| "Agent".into());
        out.push(CursorComposerSession {
            id,
            kind,
            finished,
            label,
        });
    }
    out
}

/// Ring state from Cursor's composer DB: waiting on you outranks busy.
/// The ring's state from composers already read by `cursor_composer_sessions`.
pub fn cursor_db_session(live: &[CursorComposerSession]) -> crate::protocol::SessionState {
    let rank = |kind: SessionKind| match kind {
        SessionKind::WaitingYou => 2,
        SessionKind::Busy => 1,
        SessionKind::Idle => 0,
    };
    // Newest first: on a tie, keep the earlier (more recent) composer.
    let lead = live
        .iter()
        .enumerate()
        .max_by_key(|(index, session)| (rank(session.kind), std::cmp::Reverse(*index)));
    match lead {
        Some((_, session)) if session.kind != SessionKind::Idle => crate::protocol::SessionState {
            provider: ProviderId::Cursor,
            kind: session.kind,
            label: Some(session.label.clone()),
            updated_at: Utc::now(),
        },
        _ => crate::protocol::SessionState {
            provider: ProviderId::Cursor,
            kind: SessionKind::Idle,
            label: None,
            updated_at: Utc::now(),
        },
    }
}

fn open_cursor_state_db() -> Option<Connection> {
    let path = paths::cursor_state_db();
    if !path.exists() {
        return None;
    }
    let uri = format!("file:{}?mode=ro", path.display());
    let conn = Connection::open_with_flags(
        &uri,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )
    .ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_millis(400));
    Some(conn)
}

/// How long a Cursor turn may sit without new bubble flags before we still
/// treat it as working. Agent transcripts often stay quiet for minutes while
/// a tool runs; `status` can even say `aborted` mid-run.
pub(crate) const CURSOR_OPEN_TURN_GRACE: std::time::Duration =
    std::time::Duration::from_secs(15 * 60);

/// Kind plus whether an Idle reading is a real finish (vs sticky abandoned
/// flags that only look idle after the grace window).
pub(crate) fn cursor_composer_kind(
    head: &Value,
    data: Option<&Value>,
    updated_ms: Option<i64>,
) -> (SessionKind, bool) {
    if head
        .get("hasBlockingPendingActions")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return (SessionKind::WaitingYou, false);
    }
    let fresh = composer_recently_touched(head, data, updated_ms);
    let Some(data) = data else {
        return (SessionKind::Idle, true);
    };
    if data
        .get("isContinuationInProgress")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return (SessionKind::Busy, false);
    }
    if data
        .get("generatingBubbleIds")
        .and_then(Value::as_array)
        .is_some_and(|ids| !ids.is_empty())
    {
        return (SessionKind::Busy, false);
    }
    if let Some("generating" | "streaming" | "in_progress" | "running") =
        data.get("status").and_then(Value::as_str)
    {
        return (SessionKind::Busy, false);
    }
    // Live generation: Cursor sets this while a turn is open, and clears it
    // when the composer completes. Sticky after a hard abort — only trust it
    // while the composer was touched recently.
    let sticky_generation = data
        .get("chatGenerationUUID")
        .is_some_and(|value| !value.is_null());
    let sticky_unfinished = head
        .get("unfinishedRunAt")
        .is_some_and(|value| !value.is_null())
        || data
            .get("unfinishedRunAt")
            .is_some_and(|value| !value.is_null());
    if sticky_generation || sticky_unfinished {
        if fresh {
            return (SessionKind::Busy, false);
        }
        // Grace expired with sticky flags still set: idle for the ring, but
        // not a finish to announce.
        return (SessionKind::Idle, false);
    }
    (SessionKind::Idle, true)
}

fn composer_recently_touched(head: &Value, data: Option<&Value>, updated_ms: Option<i64>) -> bool {
    let now = Utc::now().timestamp_millis();
    let grace = CURSOR_OPEN_TURN_GRACE.as_millis() as i64;
    let candidates = [
        updated_ms,
        head.get("unfinishedRunAt").and_then(Value::as_i64),
        data.and_then(|value| value.get("unfinishedRunAt").and_then(Value::as_i64)),
        head.get("lastUpdatedAt").and_then(Value::as_i64),
    ];
    candidates
        .into_iter()
        .flatten()
        .any(|ms| now.saturating_sub(ms) < grace)
}

fn cursor_composer_data(conn: &Connection, composer_id: &str) -> Option<Value> {
    let key = format!("composerData:{composer_id}");
    let raw = conn
        .query_row(
            "SELECT value FROM cursorDiskKV WHERE key = ?1",
            [&key],
            |row| match row.get_ref(0)? {
                rusqlite::types::ValueRef::Text(bytes) | rusqlite::types::ValueRef::Blob(bytes) => {
                    Ok(String::from_utf8_lossy(bytes).into_owned())
                }
                other => Err(rusqlite::Error::InvalidColumnType(
                    0,
                    "value".into(),
                    other.data_type(),
                )),
            },
        )
        .ok()?;
    serde_json::from_str(&raw).ok()
}

/// Model chosen for a Cursor composer, from `composerData:<id>` in the same DB.
fn cursor_composer_model(conn: &Connection, composer_id: &str) -> Option<String> {
    cursor_model_from_data(&cursor_composer_data(conn, composer_id)?)
}

fn cursor_model_from_data(data: &Value) -> Option<String> {
    let config = data.get("modelConfig")?;
    let id = config
        .get("modelName")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            config
                .pointer("/selectedModels/0/modelId")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        })?;
    // Cursor's Auto picker is stored as the literal id `default`.
    if id.eq_ignore_ascii_case("default") {
        Some("Auto".into())
    } else {
        Some(pretty_model(id))
    }
}

// ---------------------------------------------------------------------------
// GitHub Copilot Chat
// ---------------------------------------------------------------------------

fn copilot_chats(memo: &mut FileMemo<Option<ChatSummary>>) -> Vec<ChatSummary> {
    let mut chats = Vec::new();

    for product in paths::vscode_product_dirs() {
        let storage = product.join("User/workspaceStorage");
        let Ok(entries) = std::fs::read_dir(storage) else {
            continue;
        };
        for entry in entries.flatten() {
            let workspace = entry.path();
            let sessions = workspace.join("chatSessions");
            let cwd = workspace_path(&workspace);
            let Ok(files) = std::fs::read_dir(sessions) else {
                continue;
            };
            for file in files.flatten() {
                let path = file.path();
                if path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
                    continue;
                }
                let Ok(meta) = std::fs::metadata(&path) else {
                    continue;
                };
                let found = memo.get(&path, &meta, || {
                    copilot_read_session(&path)
                        .map(|state| copilot_chat_summary(&state, cwd.as_deref()))
                });
                let Some(Some(mut chat)) = found else {
                    continue;
                };
                // The workspace's folder is read fresh; only the session is kept.
                chat.project = cwd.as_deref().map(folder_name);
                chat.cwd = cwd.clone();
                chats.push(chat);
            }
        }
    }
    memo.finish_pass();

    chats.sort_by_key(|c| std::cmp::Reverse(c.updated_at));
    chats.truncate(MAX_CHATS);
    chats
}

fn workspace_path(storage: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(storage.join("workspace.json")).ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    let folder = value.get("folder")?.as_str()?;
    folder
        .strip_prefix("file://")
        .filter(|path| !path.is_empty())
        .map(str::to_string)
}

#[cfg(test)]
fn copilot_chat_file(path: &Path, cwd: Option<&str>) -> Option<ChatSummary> {
    copilot_chat_summary(&copilot_read_session(path)?, cwd)
}

/// `None` for a session that is not a chat yet.
fn copilot_chat_summary(state: &Value, cwd: Option<&str>) -> Option<ChatSummary> {
    let id = state.get("sessionId")?.as_str()?.to_string();
    let requests = state.get("requests").and_then(Value::as_array);
    // VS Code persists a session as soon as the Chat panel is opened. Until
    // the user sends something it is only editor state, not a real chat.
    if requests.is_none_or(Vec::is_empty) {
        return None;
    }
    let latest = requests.and_then(|items| items.last());
    let title = state
        .get("customTitle")
        .and_then(Value::as_str)
        .and_then(|text| clean_title(Some(text)))
        .or_else(|| {
            requests.and_then(|items| {
                items.iter().find_map(|request| {
                    request
                        .pointer("/message/text")
                        .and_then(Value::as_str)
                        .or_else(|| {
                            request
                                .pointer("/message/parts/0/text")
                                .and_then(Value::as_str)
                        })
                        .and_then(|text| clean_title(Some(text)))
                })
            })
        })
        .unwrap_or_else(|| "GitHub Copilot chat".to_string());
    let updated_ms = latest
        .and_then(|request| request.get("timestamp").and_then(Value::as_i64))
        .or_else(|| state.get("lastMessageDate").and_then(Value::as_i64))
        .or_else(|| state.get("creationDate").and_then(Value::as_i64))?;
    let updated_at = Utc.timestamp_millis_opt(updated_ms).single()?;
    let model = latest
        .and_then(|request| request.get("modelId").and_then(Value::as_str))
        .or_else(|| {
            state
                .pointer("/inputState/selectedModel/identifier")
                .and_then(Value::as_str)
        })
        .map(|model| pretty_model(model.strip_prefix("copilot/").unwrap_or(model)));
    let waiting = state
        .get("pendingRequests")
        .and_then(Value::as_array)
        .is_some_and(|pending| !pending.is_empty());

    Some(ChatSummary {
        provider: ProviderId::Copilot,
        id,
        title,
        project: cwd.map(folder_name),
        cwd: cwd.map(str::to_string),
        model,
        surface: Some("VS Code".into()),
        preview: None,
        avatar_shape: None,
        avatar_color: None,
        state: if waiting {
            SessionKind::WaitingYou
        } else {
            SessionKind::Idle
        },
        live: waiting,
        updated_at,
        messages: requests.map_or(0, Vec::len) as u32,
        tokens: None,
        context_tokens: None,
        context_pct: None,
        lines_added: None,
        lines_removed: None,
        unread: false,
        prompted_at: None,
        replied_at: None,
    })
}

/// VS Code Copilot Chat sessions are a JSONL patch log: `kind` 0 is the
/// initial state, `kind` 1 sets a path, `kind` 2 appends to an array path.
/// Titles and requests live in later lines, so the first line alone is empty.
fn copilot_read_session(path: &Path) -> Option<Value> {
    let file = std::fs::File::open(path).ok()?;
    let mut state: Option<Value> = None;
    for line in BufReader::new(file).lines() {
        let line = line.ok()?;
        if line.trim().is_empty() {
            continue;
        }
        let row: Value = serde_json::from_str(&line).ok()?;
        match row.get("kind").and_then(Value::as_i64) {
            Some(0) => state = row.get("v").cloned(),
            Some(1) | Some(2) => {
                let Some(path) = row.get("k").and_then(Value::as_array) else {
                    continue;
                };
                let Some(value) = row.get("v").cloned() else {
                    continue;
                };
                let append = row.get("kind").and_then(Value::as_i64) == Some(2);
                let root = state.get_or_insert_with(|| Value::Object(Default::default()));
                copilot_set_path(root, path, value, append);
            }
            _ => {
                // Older builds wrote the whole session as one JSON object.
                if state.is_none() && row.get("sessionId").is_some() {
                    state = Some(row);
                }
            }
        }
    }
    state
}

fn copilot_set_path(root: &mut Value, path: &[Value], value: Value, append: bool) {
    if path.is_empty() {
        *root = value;
        return;
    }
    let (last, lead) = path.split_last().expect("path is not empty");
    let parent = copilot_ensure_path(root, lead);
    match last.as_str() {
        Some(name) => {
            let obj = match parent {
                Value::Object(map) => map,
                _ => {
                    *parent = Value::Object(Default::default());
                    parent.as_object_mut().expect("object")
                }
            };
            if append {
                let entry = obj
                    .entry(name.to_string())
                    .or_insert_with(|| Value::Array(Vec::new()));
                if !entry.is_array() {
                    *entry = Value::Array(Vec::new());
                }
                let arr = entry.as_array_mut().expect("array");
                match value {
                    Value::Array(items) => arr.extend(items),
                    other => arr.push(other),
                }
            } else {
                obj.insert(name.to_string(), value);
            }
        }
        None => {
            let Some(idx) = last.as_u64().or_else(|| last.as_i64().map(|n| n as u64)) else {
                return;
            };
            let idx = idx as usize;
            let arr = match parent {
                Value::Array(items) => items,
                _ => {
                    *parent = Value::Array(Vec::new());
                    parent.as_array_mut().expect("array")
                }
            };
            while arr.len() <= idx {
                arr.push(Value::Null);
            }
            if append {
                if !arr[idx].is_array() {
                    arr[idx] = Value::Array(Vec::new());
                }
                let target = arr[idx].as_array_mut().expect("array");
                match value {
                    Value::Array(items) => target.extend(items),
                    other => target.push(other),
                }
            } else {
                arr[idx] = value;
            }
        }
    }
}

fn copilot_ensure_path<'a>(root: &'a mut Value, path: &[Value]) -> &'a mut Value {
    let mut cur = root;
    for (i, key) in path.iter().enumerate() {
        let next_is_index = path
            .get(i + 1)
            .is_some_and(|k| k.as_u64().is_some() || k.as_i64().is_some());
        if let Some(name) = key.as_str() {
            if !cur.is_object() {
                *cur = Value::Object(Default::default());
            }
            let obj = cur.as_object_mut().expect("object");
            obj.entry(name.to_string()).or_insert_with(|| {
                if next_is_index {
                    Value::Array(Vec::new())
                } else {
                    Value::Object(Default::default())
                }
            });
            let next = obj.get_mut(name).expect("entry");
            if next_is_index && !next.is_array() {
                *next = Value::Array(Vec::new());
            } else if !next_is_index && !next.is_object() {
                *next = Value::Object(Default::default());
            }
            cur = obj.get_mut(name).expect("entry");
        } else if let Some(idx) = key.as_u64().or_else(|| key.as_i64().map(|n| n as u64)) {
            let idx = idx as usize;
            if !cur.is_array() {
                *cur = Value::Array(Vec::new());
            }
            let arr = cur.as_array_mut().expect("array");
            while arr.len() <= idx {
                arr.push(if next_is_index {
                    Value::Array(Vec::new())
                } else {
                    Value::Object(Default::default())
                });
            }
            if next_is_index && !arr[idx].is_array() {
                arr[idx] = Value::Array(Vec::new());
            } else if !next_is_index && !arr[idx].is_object() {
                arr[idx] = Value::Object(Default::default());
            }
            cur = &mut arr[idx];
        } else {
            break;
        }
    }
    cur
}

// ---------------------------------------------------------------------------
// Codex chats
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct CodexIndexRow {
    id: String,
    thread_name: Option<String>,
    updated_at: String,
}

#[derive(Debug, Default)]
struct CodexRolloutMeta {
    cwd: Option<String>,
    surface: Option<String>,
    model: Option<String>,
    /// Subagent / guardian threads are not listed as their own chats.
    skip: bool,
}

/// Recent Codex threads from the local index and rollout headers.
#[cfg(test)]
fn codex_chats_from(home: &Path) -> Vec<ChatSummary> {
    codex_chats_at(
        &home.join("session_index.jsonl"),
        &home.join("sessions"),
        &ProviderId::Codex,
    )
}

fn codex_chats_at(index_path: &Path, sessions_dir: &Path, id: &ProviderId) -> Vec<ChatSummary> {
    let Ok(raw) = std::fs::read_to_string(index_path) else {
        return Vec::new();
    };

    // A rename appends a row with the same id; the latest one wins.
    let mut latest: HashMap<String, (CodexIndexRow, DateTime<Utc>)> = HashMap::new();
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(row) = serde_json::from_str::<CodexIndexRow>(line) else {
            continue;
        };
        let Ok(updated_at) = DateTime::parse_from_rfc3339(&row.updated_at) else {
            continue;
        };
        latest.insert(row.id.clone(), (row, updated_at.with_timezone(&Utc)));
    }
    let mut rows: Vec<_> = latest.into_values().collect();
    rows.sort_by_key(|row| std::cmp::Reverse(row.1));

    let rollouts = codex_rollout_index(sessions_dir);
    let mut chats = Vec::new();
    for (row, updated_at) in rows {
        let Some(title) = clean_title(row.thread_name.as_deref()) else {
            continue;
        };
        let meta = rollouts
            .get(&row.id)
            .map(|path| read_codex_rollout_meta(path))
            .unwrap_or_default();
        if meta.skip {
            continue;
        }
        let cwd = meta.cwd;
        chats.push(ChatSummary {
            provider: id.clone(),
            id: row.id,
            title,
            project: cwd.as_deref().map(folder_name),
            cwd,
            model: meta.model.as_deref().map(pretty_model),
            surface: meta.surface,
            preview: None,
            avatar_shape: None,
            avatar_color: None,
            state: SessionKind::Idle,
            live: false,
            updated_at,
            messages: 0,
            tokens: None,
            context_tokens: None,
            context_pct: None,
            lines_added: None,
            lines_removed: None,
            unread: false,
            prompted_at: None,
            replied_at: None,
        });
        if chats.len() == MAX_CHATS {
            break;
        }
    }
    chats
}

/// Map session id → plain `.jsonl` rollout path (skip `.zst`).
fn codex_rollout_index(sessions: &Path) -> HashMap<String, PathBuf> {
    let mut out = HashMap::new();
    if !sessions.is_dir() {
        return out;
    }
    for entry in WalkDir::new(sessions).into_iter().flatten() {
        if !entry.file_type().is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy();
        let Some(id) = codex_rollout_id(&name) else {
            continue;
        };
        out.insert(id, entry.path().to_path_buf());
    }
    out
}

/// `rollout-<timestamp>-<uuid>.jsonl` → uuid. Compressed `.zst` files are ignored.
fn codex_rollout_id(file_name: &str) -> Option<String> {
    let stem = file_name.strip_prefix("rollout-")?.strip_suffix(".jsonl")?;
    if stem.len() < 36 {
        return None;
    }
    let id = &stem[stem.len() - 36..];
    let bytes = id.as_bytes();
    if bytes.get(8) == Some(&b'-')
        && bytes.get(13) == Some(&b'-')
        && bytes.get(18) == Some(&b'-')
        && bytes.get(23) == Some(&b'-')
    {
        Some(id.to_string())
    } else {
        None
    }
}

fn read_codex_rollout_meta(path: &Path) -> CodexRolloutMeta {
    let Ok(file) = std::fs::File::open(path) else {
        return CodexRolloutMeta::default();
    };
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut meta = CodexRolloutMeta::default();
    let mut saw_meta = false;
    // session_meta is first; the model usually appears a few lines later on
    // turn_context (provenance on session_meta is only set for some threads).
    for _ in 0..24 {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        let typ = value.get("type").and_then(Value::as_str);
        let Some(payload) = value.get("payload") else {
            continue;
        };

        if typ == Some("session_meta") {
            saw_meta = true;
            meta.skip = payload
                .get("parent_thread_id")
                .and_then(Value::as_str)
                .is_some()
                || payload
                    .get("thread_source")
                    .and_then(Value::as_str)
                    .is_some_and(|s| s != "user")
                || payload
                    .get("source")
                    .and_then(Value::as_object)
                    .is_some_and(|o| o.contains_key("subagent"));
            meta.cwd = payload
                .get("cwd")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            meta.surface = codex_surface(
                payload.get("originator").and_then(Value::as_str),
                payload.get("source"),
            );
            // Fallback when the rollout never emits turn_context.model.
            if meta.model.is_none() {
                if let Some(model) = payload
                    .pointer("/base_instructions/provenance/model")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                {
                    meta.model = Some(model.to_string());
                }
            }
        }

        let from_payload = payload
            .get("model")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        if let Some(model) = from_payload {
            meta.model = Some(model);
            if saw_meta {
                break;
            }
        } else if saw_meta && typ == Some("turn_context") {
            break;
        }
    }
    if saw_meta {
        meta
    } else {
        CodexRolloutMeta::default()
    }
}

fn codex_surface(originator: Option<&str>, source: Option<&Value>) -> Option<String> {
    if let Some(originator) = originator {
        let lower = originator.to_ascii_lowercase();
        if lower.contains("desktop") {
            return Some("Desktop".into());
        }
        if lower.contains("cli") {
            return Some("CLI".into());
        }
    }
    match source {
        Some(Value::String(s)) => match s.as_str() {
            "vscode" => Some("VS Code".into()),
            "cli" => Some("CLI".into()),
            other => Some(capitalize(other)),
        },
        _ => originator.map(capitalize),
    }
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

/// A slash command typed with something to do, such as `/goal ship it`, as
/// the transcript keeps it (`<command-name>/goal</command-name>` …
/// `<command-args>ship it</command-args>`). One without arguments (`/clear`,
/// `/compact`) says nothing about the chat.
fn command_title(text: &str) -> Option<String> {
    fn tag<'a>(text: &'a str, name: &str) -> Option<&'a str> {
        let open = format!("<{name}>");
        let start = text.find(&open)? + open.len();
        let end = text[start..].find(&format!("</{name}>"))? + start;
        Some(text[start..end].trim())
    }
    let name = tag(text, "command-name")?;
    let args = tag(text, "command-args")?;
    if args.is_empty() {
        return None;
    }
    let name = if name.starts_with('/') {
        name.to_string()
    } else {
        format!("/{name}")
    };
    clean_title(Some(&format!("{name} {args}")))
}

/// One line, trimmed and bounded. Harness-injected text (`<command-name>`,
/// `<system-reminder>`…) is not something the user typed, so it is no title.
pub(crate) fn clean_title(raw: Option<&str>) -> Option<String> {
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
            words.push(model_word(part));
        }
    }
    flush(&mut version, &mut words);

    if words.is_empty() {
        id.to_string()
    } else {
        words.join(" ")
    }
}

/// Brands keep the casing their vendor uses; everything else is capitalised.
fn model_word(word: &str) -> String {
    match word.to_ascii_lowercase().as_str() {
        "gpt" => "GPT".into(),
        "glm" => "GLM".into(),
        "deepseek" => "DeepSeek".into(),
        "minimax" => "MiniMax".into(),
        "openai" => "OpenAI".into(),
        _ => capitalize(word),
    }
}

/// Repairs labels already written to history before the brands were known,
/// so old dashboard rows read like new ones.
pub fn normalize_model_label(label: &str) -> String {
    label
        .split(' ')
        .map(model_word)
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subagents_belong_to_the_session_that_ran_them() {
        let root = Path::new("/home/me/.claude/projects");
        let id = |rel: &str| claude_session_id(root, &root.join(rel));
        assert_eq!(id("-home-me-app/abc.jsonl"), Some(("abc".into(), true)));
        assert_eq!(
            id("-home-me-app/abc/subagents/agent-1.jsonl"),
            Some(("abc".into(), false))
        );
        assert_eq!(id("stray.jsonl"), None);
        assert_eq!(
            claude_session_id(root, Path::new("/elsewhere/x.jsonl")),
            None
        );
    }

    #[test]
    fn model_names() {
        assert_eq!(pretty_model("claude-opus-5-5"), "Opus 5.5");
        assert_eq!(pretty_model("claude-haiku-4-5-20251001"), "Haiku 4.5");
        assert_eq!(pretty_model("claude-3-5-sonnet-20241022"), "3.5 Sonnet");
        assert_eq!(pretty_model("gpt"), "GPT");
        assert_eq!(pretty_model("gpt-6-astra"), "GPT 6 Astra");
        assert_eq!(pretty_model("glm-4.6"), "GLM 4.6");
        assert_eq!(
            pretty_model("deepseek-v4.1-flash-free"),
            "DeepSeek V4.1 Flash Free"
        );
        assert_eq!(
            pretty_model("minimax-m3.1-flash-free"),
            "MiniMax M3.1 Flash Free"
        );
    }

    #[test]
    fn old_labels_are_repaired_on_read() {
        assert_eq!(
            normalize_model_label("Deepseek V4.1 Flash Free · Zen"),
            "DeepSeek V4.1 Flash Free · Zen"
        );
        assert_eq!(
            normalize_model_label("Minimax M3.1 Flash Free · Zen"),
            "MiniMax M3.1 Flash Free · Zen"
        );
        assert_eq!(normalize_model_label("Opus 5.5"), "Opus 5.5");
    }

    #[test]
    fn titles() {
        assert_eq!(
            clean_title(Some("  fix\n the  bug ")).as_deref(),
            Some("fix the bug")
        );
        assert_eq!(
            clean_title(Some("<command-name>/clear</command-name>")),
            None
        );
        assert_eq!(clean_title(Some("   ")), None);
        assert_eq!(
            command_title(
                "<command-message>goal</command-message>\n<command-name>/goal</command-name>\n<command-args>ship  the\n release</command-args>"
            )
            .as_deref(),
            Some("/goal ship the release")
        );
        assert_eq!(
            command_title("<command-name>/compact</command-name><command-args></command-args>"),
            None
        );
        let long = "a".repeat(200);
        assert_eq!(
            clean_title(Some(&long)).unwrap().chars().count(),
            TITLE_CHARS
        );
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
                    "content":[{{"type":"text","text":"Hi!"}}],
                    "usage":{{"input_tokens":2,"output_tokens":{output},"cache_read_input_tokens":1000,"cache_creation_input_tokens":500}}}}}}"#
            )));
        }
        // All tool calls, nothing to read.
        t.ingest(line(
            r#"{"type":"assistant","timestamp":"2026-09-30T10:00:07Z",
                "message":{"id":"m2","content":[{"type":"tool_use","name":"Bash"}]}}"#,
        ));
        t.ingest(line(r#"{"type":"ai-title","aiTitle":"Greeting"}"#));

        assert_eq!(t.prompts, 1);
        assert_eq!(t.totals.output, 250);
        assert_eq!(t.totals.total(), 1752);
        assert_eq!(t.context_tokens, 1502);
        assert_eq!(t.title().as_deref(), Some("Greeting"));
        // The tool result at :01 is not a prompt of yours.
        let time = |s: &str| Some(s.parse::<DateTime<Utc>>().unwrap());
        assert_eq!(t.prompted_at, time("2026-09-30T10:00:00Z"));
        assert_eq!(t.replied_at, time("2026-09-30T10:00:05Z"));
        let summed: u64 = t
            .days
            .values()
            .flat_map(|m| m.values())
            .map(TokenTotals::total)
            .sum();
        assert_eq!(summed, 1752);
    }

    #[test]
    fn project_and_title_survive_a_cd_and_a_slash_command() {
        let mut t = Transcript::default();
        t.ingest(line(
            r#"{"type":"user","cwd":"/w/organizer","message":{"content":"<command-name>/goal</command-name><command-args>tidy the inbox</command-args>"}}"#,
        ));
        t.ingest(line(
            r#"{"type":"user","cwd":"/w/organizer/web","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        ));
        assert_eq!(t.cwd.as_deref(), Some("/w/organizer"));
        assert_eq!(t.prompts, 1);
        assert_eq!(t.title().as_deref(), Some("/goal tidy the inbox"));

        // A prompt typed later reads better than the command.
        t.ingest(line(
            r#"{"type":"user","message":{"content":[{"type":"text","text":"<ide_opened_file>a.ts</ide_opened_file>"},{"type":"text","text":"add a filter"}]}}"#,
        ));
        assert_eq!(t.prompts, 2);
        assert_eq!(t.title().as_deref(), Some("add a filter"));
    }

    #[test]
    fn codex_rollout_file_names_end_with_the_session_id() {
        assert_eq!(
            codex_rollout_id(
                "rollout-2026-10-18T14-47-39-01a14f44-a03c-7be1-a830-5a908da660ba.jsonl"
            )
            .as_deref(),
            Some("01a14f44-a03c-7be1-a830-5a908da660ba")
        );
        assert_eq!(
            codex_rollout_id(
                "rollout-2026-08-31T13-33-42-01a057cf-ab38-75d0-b432-204f8dc88768.jsonl.zst"
            ),
            None
        );
        assert_eq!(codex_rollout_id("notes.txt"), None);
    }

    #[test]
    fn codex_chats_read_the_index_and_skip_subagents() {
        let root =
            std::env::temp_dir().join(format!("omega-notch-codex-chats-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let sessions = root.join("sessions/2026/10/18");
        std::fs::create_dir_all(&sessions).unwrap();

        let user_id = "01a14f44-a03c-7be1-a830-5a908da660ba";
        let agent_id = "01a14f47-09fd-7da2-adb3-bea01e290d4c";
        std::fs::write(
            root.join("session_index.jsonl"),
            format!(
                r#"{{"id":"{user_id}","thread_name":"Check vault access","updated_at":"2026-10-18T13:47:52Z"}}
{{"id":"{agent_id}","thread_name":"Guardian review","updated_at":"2026-10-18T13:50:18Z"}}
{{"id":"{user_id}","thread_name":"Check vault access again","updated_at":"2026-10-18T13:55:00Z"}}
"#
            ),
        )
        .unwrap();
        std::fs::write(
            sessions.join(format!("rollout-2026-10-18T14-47-39-{user_id}.jsonl")),
            format!(
                r#"{{"type":"session_meta","payload":{{"session_id":"{user_id}","cwd":"/home/me/app","originator":"Codex Desktop","source":"vscode","thread_source":"user","base_instructions":{{"provenance":{{"type":"model","model":"gpt-6-luna"}}}}}}}}
{{"type":"event_msg","payload":{{"type":"token_count","model_context_window":1000}}}}
{{"type":"turn_context","payload":{{"cwd":"/home/me/app","model":"gpt-6-luna"}}}}
"#
            ),
        )
        .unwrap();
        std::fs::write(
            sessions.join(format!("rollout-2026-10-18T14-50-18-{agent_id}.jsonl")),
            format!(
                r#"{{"type":"session_meta","payload":{{"session_id":"{agent_id}","parent_thread_id":"{user_id}","cwd":"/home/me/app","originator":"Codex Desktop","source":{{"subagent":{{"other":"guardian"}}}},"thread_source":"guardian_review"}}}}
{{"type":"turn_context","payload":{{"model":"codex-auto-review"}}}}
"#
            ),
        )
        .unwrap();

        let chats = codex_chats_from(&root);
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(chats.len(), 1);
        assert_eq!(chats[0].provider, ProviderId::Codex);
        assert_eq!(chats[0].id, user_id);
        assert_eq!(chats[0].title, "Check vault access again");
        assert_eq!(chats[0].project.as_deref(), Some("app"));
        assert_eq!(chats[0].cwd.as_deref(), Some("/home/me/app"));
        assert_eq!(chats[0].surface.as_deref(), Some("Desktop"));
        assert_eq!(chats[0].model.as_deref(), Some("GPT 6 Luna"));
        assert!(!chats[0].live);
    }

    #[test]
    fn cursor_chats_read_the_model_from_composer_data() {
        let root =
            std::env::temp_dir().join(format!("omega-notch-cursor-chats-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let db = root.join("state.vscdb");
        let conn = Connection::open(&db).unwrap();
        conn.execute_batch(
            "CREATE TABLE composerHeaders(
                composerId TEXT PRIMARY KEY,
                lastUpdatedAt INTEGER,
                createdAt INTEGER,
                value TEXT,
                isSubagent INTEGER,
                isArchived INTEGER,
                recency INTEGER
             );
             CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value BLOB);",
        )
        .unwrap();

        let auto_id = "11111111-1111-1111-1111-111111111111";
        let named_id = "22222222-2222-2222-2222-222222222222";
        let now = 1_700_000_000_000i64;
        conn.execute(
            "INSERT INTO composerHeaders(composerId, lastUpdatedAt, createdAt, value, isSubagent, isArchived, recency)
             VALUES (?1, ?2, ?2, ?3, 0, 0, 2)",
            rusqlite::params![
                auto_id,
                now + 2,
                r#"{"name":"Auto chat","unifiedMode":"agent","workspaceIdentifier":{"uri":{"fsPath":"/home/me/app"}}}"#,
            ],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO composerHeaders(composerId, lastUpdatedAt, createdAt, value, isSubagent, isArchived, recency)
             VALUES (?1, ?2, ?2, ?3, 0, 0, 1)",
            rusqlite::params![
                named_id,
                now + 1,
                r#"{"name":"Named chat","unifiedMode":"agent","workspaceIdentifier":{"uri":{"fsPath":"/home/me/app"}}}"#,
            ],
        )
        .unwrap();
        // Real Cursor DBs store composerData as TEXT.
        conn.execute(
            "INSERT INTO cursorDiskKV(key, value) VALUES (?1, ?2)",
            rusqlite::params![
                format!("composerData:{auto_id}"),
                r#"{"modelConfig":{"modelName":"default","selectedModels":[{"modelId":"default"}]}}"#,
            ],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO cursorDiskKV(key, value) VALUES (?1, ?2)",
            rusqlite::params![
                format!("composerData:{named_id}"),
                r#"{"modelConfig":{"modelName":"claude-opus-5-5","selectedModels":[{"modelId":"claude-opus-5-5"}]}}"#,
            ],
        )
        .unwrap();
        drop(conn);

        let uri = format!("file:{}?mode=ro", db.display());
        let conn = Connection::open_with_flags(
            &uri,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        )
        .unwrap();
        assert_eq!(
            cursor_composer_model(&conn, auto_id).as_deref(),
            Some("Auto")
        );
        assert_eq!(
            cursor_composer_model(&conn, named_id).as_deref(),
            Some("Opus 5.5")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cursor_composer_kind_prefers_waiting_then_busy() {
        let now_ms = Utc::now().timestamp_millis();
        let waiting = serde_json::json!({"hasBlockingPendingActions": true});
        assert_eq!(
            cursor_composer_kind(&waiting, None, Some(now_ms)),
            (SessionKind::WaitingYou, false)
        );

        let idle_head = serde_json::json!({"hasBlockingPendingActions": false});
        let generating = serde_json::json!({
            "generatingBubbleIds": ["bubble-1"],
            "status": "completed"
        });
        assert_eq!(
            cursor_composer_kind(&idle_head, Some(&generating), Some(now_ms)),
            (SessionKind::Busy, false)
        );

        let continuing = serde_json::json!({
            "isContinuationInProgress": true,
            "generatingBubbleIds": []
        });
        assert_eq!(
            cursor_composer_kind(&idle_head, Some(&continuing), Some(now_ms)),
            (SessionKind::Busy, false)
        );

        let with_generation = serde_json::json!({
            "status": "aborted",
            "generatingBubbleIds": [],
            "chatGenerationUUID": "33026c60-0919-4ff1-b1af-006cf545a177",
            "unfinishedRunAt": now_ms
        });
        assert_eq!(
            cursor_composer_kind(&idle_head, Some(&with_generation), Some(now_ms)),
            (SessionKind::Busy, false)
        );

        let stale_ms = now_ms - 20 * 60 * 1000;
        let stale_generation = serde_json::json!({
            "status": "aborted",
            "chatGenerationUUID": "33026c60-0919-4ff1-b1af-006cf545a177",
            "unfinishedRunAt": stale_ms
        });
        assert_eq!(
            cursor_composer_kind(&idle_head, Some(&stale_generation), Some(stale_ms)),
            (SessionKind::Idle, false)
        );

        let done = serde_json::json!({
            "status": "completed",
            "generatingBubbleIds": [],
            "isContinuationInProgress": false
        });
        assert_eq!(
            cursor_composer_kind(&idle_head, Some(&done), Some(now_ms)),
            (SessionKind::Idle, true)
        );
    }

    #[test]
    fn copilot_chats_read_titles_from_jsonl_patches() {
        let root =
            std::env::temp_dir().join(format!("omega-notch-copilot-chats-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let sessions = root.join("chatSessions");
        std::fs::create_dir_all(&sessions).unwrap();

        let session_id = "b0231bf7-047d-4cbe-9872-0a3b43d3f6c5";
        std::fs::write(
            sessions.join(format!("{session_id}.jsonl")),
            format!(
                r#"{{"kind":0,"v":{{"version":3,"creationDate":1792503317985,"sessionId":"{session_id}","requests":[],"pendingRequests":[],"inputState":{{"selectedModel":{{"identifier":"copilot/auto"}}}}}}}}
{{"kind":1,"k":["customTitle"],"v":"Resolve OS problems in .py"}}
{{"kind":2,"k":["requests"],"v":[{{"requestId":"request_1","timestamp":1792503353191,"modelId":"copilot/auto","message":{{"text":"resolve os 4 problems deste .py","parts":[{{"text":"resolve os 4 problems deste .py"}}]}}}}]}}
"#
            ),
        )
        .unwrap();

        let chat = copilot_chat_file(
            &sessions.join(format!("{session_id}.jsonl")),
            Some("/home/me/omega-notch"),
        )
        .unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(chat.provider, ProviderId::Copilot);
        assert_eq!(chat.id, session_id);
        assert_eq!(chat.title, "Resolve OS problems in .py");
        assert_eq!(chat.project.as_deref(), Some("omega-notch"));
        assert_eq!(chat.model.as_deref(), Some("Auto"));
        assert_eq!(chat.messages, 1);
        assert!(!chat.live);
    }

    #[test]
    fn copilot_chats_fall_back_to_first_prompt_without_custom_title() {
        let root = std::env::temp_dir().join(format!(
            "omega-notch-copilot-prompt-title-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let sessions = root.join("chatSessions");
        std::fs::create_dir_all(&sessions).unwrap();

        let session_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
        std::fs::write(
            sessions.join(format!("{session_id}.jsonl")),
            format!(
                r#"{{"kind":0,"v":{{"version":3,"creationDate":1792503317985,"sessionId":"{session_id}","requests":[],"pendingRequests":[]}}}}
{{"kind":2,"k":["requests"],"v":[{{"requestId":"request_1","timestamp":1792503353191,"modelId":"copilot/gpt-5","message":{{"text":"fix the notch title bug"}}}}]}}
"#
            ),
        )
        .unwrap();

        let chat = copilot_chat_file(
            &sessions.join(format!("{session_id}.jsonl")),
            Some("/home/me/app"),
        )
        .unwrap();
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(chat.title, "fix the notch title bug");
        assert_eq!(chat.model.as_deref(), Some("GPT 5"));
    }

    #[test]
    fn copilot_chats_skip_empty_editor_sessions() {
        let root = std::env::temp_dir().join(format!(
            "omega-notch-copilot-empty-session-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let sessions = root.join("chatSessions");
        std::fs::create_dir_all(&sessions).unwrap();

        let session_id = "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb";
        let path = sessions.join(format!("{session_id}.jsonl"));
        std::fs::write(
            &path,
            format!(
                r#"{{"kind":0,"v":{{"version":3,"creationDate":1792503317985,"sessionId":"{session_id}","requests":[],"pendingRequests":[],"inputState":{{"selectedModel":{{"identifier":"copilot/auto"}}}}}}}}
"#
            ),
        )
        .unwrap();

        assert!(copilot_chat_file(&path, Some("/home/me/app")).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }
}
