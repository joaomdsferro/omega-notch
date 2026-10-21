use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use chrono::Utc;
use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tracing::info;
use walkdir::WalkDir;

use crate::chats::{self, LiveSession};
use crate::paths;
use crate::protocol::{ProviderId, SessionKind, SessionState};
use crate::providers::profiles;
use crate::store::UsageStore;

#[derive(Debug, Clone)]
pub struct SessionEvent {
    pub provider: ProviderId,
    pub kind: SessionKind,
    pub label: Option<String>,
}

/// Chats are re-read at most this often, however fast transcripts are written.
const ACTIVITY_INTERVAL: Duration = Duration::from_secs(2);

pub fn claude_registry_available() -> bool {
    profiles::claude_profiles()
        .iter()
        .any(|profile| profile.dir.join("sessions").is_dir())
}

pub async fn watch_sessions(store: UsageStore) -> anyhow::Result<()> {
    let mut claude = ClaudeTracker::default();
    let mut opencode = OpenCodeTracker::default();

    // Initial scan
    claude.publish(&store).await;
    opencode.publish(&store).await;
    publish_cursor_best_effort(&store).await;
    publish_copilot_best_effort(&store).await;
    store.refresh_activity().await;

    let (tx, mut rx) = mpsc::unbounded_channel::<()>();

    let mut watcher = RecommendedWatcher::new(
        move |res: Result<notify::Event, notify::Error>| {
            if let Ok(event) = res {
                if matches!(
                    event.kind,
                    EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
                ) {
                    let _ = tx.send(());
                }
            }
        },
        Config::default(),
    )?;

    for profile in profiles::claude_profiles() {
        let projects = profile.dir.join("projects");
        if projects.exists() {
            watcher.watch(&projects, RecursiveMode::Recursive)?;
            info!(path = %projects.display(), "watching Claude project transcripts");
        }
        let registry = profile.dir.join("sessions");
        if registry.exists() {
            watcher.watch(&registry, RecursiveMode::NonRecursive)?;
            info!(path = %registry.display(), "watching Claude session registry");
        }
    }
    if !profiles::claude_profiles()
        .iter()
        .any(|profile| profile.dir.join("projects").exists())
    {
        info!("Claude projects dir missing — session watch idle until created");
    }

    // Also poll periodically in case inotify misses or Cursor/Copilot state changes.
    // 2s keeps best-effort busy→idle snappy; Claude registry watches already push sooner.
    let mut ticker = tokio::time::interval(Duration::from_secs(2));
    let mut activity_ticker = tokio::time::interval(ACTIVITY_INTERVAL);
    let mut activity_dirty = false;
    let mut activity_at = Instant::now();

    loop {
        tokio::select! {
            _ = rx.recv() => {
                // debounce
                tokio::time::sleep(Duration::from_millis(250)).await;
                while rx.try_recv().is_ok() {}
                claude.publish(&store).await;
                activity_dirty = true;
            }
            _ = ticker.tick() => {
                claude.publish(&store).await;
                opencode.publish(&store).await;
                publish_cursor_best_effort(&store).await;
                publish_copilot_best_effort(&store).await;
                activity_dirty = true;
            }
            _ = activity_ticker.tick() => {}
        }

        if activity_dirty && activity_at.elapsed() >= ACTIVITY_INTERVAL {
            store.refresh_activity().await;
            activity_dirty = false;
            activity_at = Instant::now();
        }
    }
}

/// Remembers each live Claude Code session so that one finishing is announced
/// even while another keeps the provider busy.
#[derive(Default)]
struct ClaudeTracker {
    known: HashMap<u32, SessionKind>,
    /// Sessions already running at launch arrive with no history; treating
    /// that as a transition would ring once per open window on every start.
    primed: bool,
}

impl ClaudeTracker {
    async fn publish(&mut self, store: &UsageStore) {
        let mut announced: Vec<(ProviderId, SessionState)> = Vec::new();
        let mut known = HashMap::new();
        for profile in profiles::claude_profiles() {
            let live = match chats::read_claude_sessions(&profile.dir.join("sessions")) {
                Some(live) => live,
                None => {
                    let state = detect_claude_session(&profile.dir, &profile.id);
                    store.apply_session(state).await;
                    continue;
                }
            };

            if self.primed {
                for session in &live {
                    let before = self.known.get(&session.pid).copied();
                    let announce = match (before, session.state) {
                        (Some(SessionKind::Busy), SessionKind::Idle) => true,
                        (Some(prev), SessionKind::WaitingYou) => prev != SessionKind::WaitingYou,
                        (None, SessionKind::WaitingYou) => true,
                        _ => false,
                    };
                    if announce {
                        announced.push((
                            profile.id.clone(),
                            SessionState {
                                provider: profile.id.clone(),
                                kind: session.state,
                                label: Some(session_label(session)),
                                updated_at: session.updated_at,
                            },
                        ));
                    }
                }
            }

            let mut live = live;
            live.sort_by_key(|s| s.pid);
            for session in &live {
                known.insert(session.pid, session.state);
            }
            store
                .set_session(summarize_claude(&live, &profile.id))
                .await;
        }
        self.known = known;
        self.primed = true;

        for (_, state) in announced {
            store.announce(state).await;
        }
    }
}

/// opencode keeps no process registry: its database is the only trace, and a
/// turn's latest message says whether it is still running. Polled with the
/// ticker, since writes to the database raise no filesystem event we watch.
#[derive(Default)]
struct OpenCodeTracker {
    known: HashMap<String, SessionKind>,
    primed: bool,
}

impl OpenCodeTracker {
    async fn publish(&mut self, store: &UsageStore) {
        let live = crate::opencode::live_sessions();
        if self.primed {
            for session in &live {
                let before = self.known.get(&session.id).copied();
                let announce = match (before, session.kind) {
                    (Some(prev), SessionKind::Idle) if prev != SessionKind::Idle => true,
                    (_, SessionKind::WaitingYou) if before != Some(SessionKind::WaitingYou) => true,
                    _ => false,
                };
                if announce {
                    store
                        .announce(SessionState {
                            provider: ProviderId::OpenCode,
                            kind: session.kind,
                            label: Some(session.title.clone()),
                            updated_at: session.updated_at,
                        })
                        .await;
                }
            }
        }
        self.known = live
            .iter()
            .map(|session| (session.id.clone(), session.kind))
            .collect();
        self.primed = true;

        let rank = |kind: SessionKind| match kind {
            SessionKind::WaitingYou => 2,
            SessionKind::Busy => 1,
            SessionKind::Idle => 0,
        };
        let lead = live
            .iter()
            .max_by_key(|session| (rank(session.kind), session.updated_at));
        let state = match lead {
            Some(session) if session.kind != SessionKind::Idle => SessionState {
                provider: ProviderId::OpenCode,
                kind: session.kind,
                label: Some(session.title.clone()),
                updated_at: session.updated_at,
            },
            _ => SessionState {
                provider: ProviderId::OpenCode,
                kind: SessionKind::Idle,
                label: None,
                updated_at: Utc::now(),
            },
        };
        store.set_session(state).await;
    }
}

fn session_label(session: &LiveSession) -> String {
    match (&session.waiting_for, session.state) {
        (Some(what), SessionKind::WaitingYou) => format!("{} — {what}", session.name),
        _ => session.name.clone(),
    }
}

/// One state for the ring: a session waiting on you outranks a busy one,
/// which outranks idle. Ties go to whichever changed last.
fn summarize_claude(live: &[LiveSession], provider: &ProviderId) -> SessionState {
    let rank = |kind: SessionKind| match kind {
        SessionKind::WaitingYou => 2,
        SessionKind::Busy => 1,
        SessionKind::Idle => 0,
    };
    let lead = live.iter().max_by_key(|s| (rank(s.state), s.updated_at));

    match lead {
        Some(session) if session.state != SessionKind::Idle => SessionState {
            provider: provider.clone(),
            kind: session.state,
            label: Some(session_label(session)),
            updated_at: session.updated_at,
        },
        _ => SessionState {
            provider: provider.clone(),
            kind: SessionKind::Idle,
            label: None,
            updated_at: Utc::now(),
        },
    }
}

async fn publish_cursor_best_effort(store: &UsageStore) {
    let state = detect_cursor_session();
    store.apply_session(state).await;
}

async fn publish_copilot_best_effort(store: &UsageStore) {
    let state = detect_copilot_session();
    store.apply_session(state).await;
}

/// Fallback for Claude Code builds without a session registry: guess from
/// which transcripts were written to recently.
fn detect_claude_session(dir: &Path, provider: &ProviderId) -> crate::protocol::SessionState {
    let projects = dir.join("projects");
    let now = SystemTime::now();
    let mut best: Option<(SystemTime, SessionKind, String)> = None;

    if projects.exists() {
        for entry in WalkDir::new(&projects)
            .max_depth(3)
            .into_iter()
            .flatten()
            .filter(|e| {
                e.file_type().is_file()
                    && e.path()
                        .extension()
                        .and_then(|s| s.to_str())
                        .is_some_and(|ext| ext == "jsonl")
            })
        {
            let Ok(meta) = entry.metadata() else { continue };
            let Ok(modified) = meta.modified() else {
                continue;
            };
            let age = now.duration_since(modified).unwrap_or_default();
            if age > Duration::from_secs(15 * 60) {
                continue;
            }

            let kind = classify_transcript(entry.path()).unwrap_or(SessionKind::Busy);
            let label = entry
                .path()
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("session")
                .chars()
                .take(24)
                .collect::<String>();

            match &best {
                Some((t, _, _)) if *t >= modified => {}
                _ => best = Some((modified, kind, label)),
            }
        }
    }

    // Also honour hook state file if present.
    if let Some(hook) = read_hook_state() {
        return crate::protocol::SessionState {
            provider: provider.clone(),
            kind: hook.kind,
            label: hook.label.or_else(|| best.map(|(_, _, l)| l)),
            updated_at: Utc::now(),
        };
    }

    match best {
        Some((_, kind, label)) => crate::protocol::SessionState {
            provider: provider.clone(),
            kind,
            label: Some(label),
            updated_at: Utc::now(),
        },
        None => crate::protocol::SessionState {
            provider: provider.clone(),
            kind: SessionKind::Idle,
            label: None,
            updated_at: Utc::now(),
        },
    }
}

fn classify_transcript(path: &Path) -> Option<SessionKind> {
    let raw = std::fs::read_to_string(path).ok()?;
    let last_lines: Vec<&str> = raw.lines().rev().take(40).collect();

    for line in &last_lines {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let type_str = value
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or_default();

        // Common Claude Code transcript signals.
        if type_str.contains("ask")
            || type_str == "user"
            || value
                .pointer("/message/stop_reason")
                .and_then(|v| v.as_str())
                == Some("tool_use")
        {
            // If the newest meaningful event is a user message, agent may be waiting
            // or idle — look for pending tool results / assistant.
        }

        if let Some(content) = value.pointer("/message/content") {
            let text = content.to_string().to_lowercase();
            if text.contains("permission")
                || text.contains("waiting for")
                || text.contains("needs input")
                || text.contains("ask_user")
            {
                return Some(SessionKind::WaitingYou);
            }
        }

        if type_str == "assistant" || type_str == "progress" || type_str == "tool_result" {
            return Some(SessionKind::Busy);
        }
    }

    // Recently modified transcript without clear signal → busy.
    Some(SessionKind::Busy)
}

#[derive(Debug, Deserialize)]
struct HookFile {
    kind: SessionKind,
    label: Option<String>,
}

fn read_hook_state() -> Option<HookFile> {
    let path = paths::app_data_dir().join("hooks/claude-session.json");
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

fn detect_cursor_session() -> crate::protocol::SessionState {
    // Best-effort: only agent transcripts and edit checkpoints. Walking all of
    // `.cursor/projects` also picks up MCP metadata refreshes and keeps the
    // ring busy long after the agent stopped.
    let candidates = cursor_agent_dirs();
    let now = SystemTime::now();
    let mut newest: Option<SystemTime> = None;

    for dir in candidates {
        if !dir.exists() {
            continue;
        }
        for entry in WalkDir::new(&dir).max_depth(6).into_iter().flatten() {
            if !entry.file_type().is_file() {
                continue;
            }
            let path = entry.path();
            if !cursor_activity_file(path) {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            let Ok(modified) = meta.modified() else {
                continue;
            };
            if now.duration_since(modified).unwrap_or_default() < BEST_EFFORT_RECENT {
                newest = Some(newest.map_or(modified, |t| t.max(modified)));
            }
        }
    }

    let kind = if newest.is_some() {
        SessionKind::Busy
    } else {
        SessionKind::Idle
    };

    crate::protocol::SessionState {
        provider: ProviderId::Cursor,
        kind,
        label: newest.map(|_| "Agent".to_string()),
        updated_at: Utc::now(),
    }
}

fn cursor_activity_file(path: &Path) -> bool {
    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    // Live agent chat transcripts.
    if path
        .extension()
        .and_then(|s| s.to_str())
        .is_some_and(|ext| ext == "jsonl")
        && path
            .components()
            .any(|c| c.as_os_str() == "agent-transcripts")
    {
        return true;
    }
    // Edit checkpoints written while the agent is applying diffs.
    if path.components().any(|c| c.as_os_str() == "checkpoints")
        && (name == "metadata.json" || path.components().any(|c| c.as_os_str() == "diffs"))
    {
        return true;
    }
    false
}

fn cursor_agent_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    let home = dirs::home_dir().unwrap_or_default();
    dirs.push(home.join(".cursor/projects"));
    dirs.push(paths::config_home().join("Cursor/User/globalStorage/anysphere.cursor-retrieval"));
    // Not `Cursor/logs`: the editor writes there whenever it is open, which
    // would read as an agent that never stops working.
    dirs
}

/// Fresh file mtime that counts as "still working" for Cursor / Copilot.
const BEST_EFFORT_RECENT: Duration = Duration::from_secs(20);
/// Extra window only for Copilot transcripts with a tool still running (no
/// new jsonl lines until the tool finishes).
const COPILOT_OPEN_TOOL_GRACE: Duration = Duration::from_secs(90);

fn detect_copilot_session() -> SessionState {
    // Best-effort: VS Code Copilot Chat leaves agent transcripts and tool
    // spill files under each product's config dir. There is no official
    // busy flag — same class of signal as Cursor's agent folders.
    let now = SystemTime::now();
    let mut newest_activity: Option<SystemTime> = None;
    let mut open_tool = false;

    for product in paths::vscode_product_dirs() {
        let workspace = product.join("User/workspaceStorage");
        if workspace.is_dir() {
            let Ok(entries) = std::fs::read_dir(&workspace) else {
                continue;
            };
            for entry in entries.flatten() {
                let chat = entry.path().join("GitHub.copilot-chat");
                if !chat.is_dir() {
                    continue;
                }
                scan_copilot_chat_dir(&chat, now, &mut newest_activity, &mut open_tool);
            }
        }

        let empty = product.join("User/globalStorage/emptyWindowChatSessions");
        if empty.is_dir() {
            scan_copilot_files(&empty, 1, now, &mut newest_activity, &mut open_tool);
        }

        let terminal = product.join("copilot-terminal-output");
        if terminal.is_dir() {
            scan_copilot_files(&terminal, 1, now, &mut newest_activity, &mut open_tool);
        }
    }

    let recent = newest_activity
        .is_some_and(|t| now.duration_since(t).unwrap_or_default() < BEST_EFFORT_RECENT);

    let kind = if recent || open_tool {
        SessionKind::Busy
    } else {
        SessionKind::Idle
    };

    SessionState {
        provider: ProviderId::Copilot,
        kind,
        label: (recent || open_tool).then(|| "Agent".to_string()),
        updated_at: Utc::now(),
    }
}

fn scan_copilot_chat_dir(
    chat: &Path,
    now: SystemTime,
    newest: &mut Option<SystemTime>,
    open_tool: &mut bool,
) {
    // transcripts/*.jsonl, chat-session-resources/**/content.txt, debug-logs
    scan_copilot_files(chat, 4, now, newest, open_tool);
}

fn scan_copilot_files(
    root: &Path,
    max_depth: usize,
    now: SystemTime,
    newest: &mut Option<SystemTime>,
    open_tool: &mut bool,
) {
    for entry in WalkDir::new(root)
        .max_depth(max_depth)
        .into_iter()
        .flatten()
    {
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if !copilot_activity_file(path) {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(modified) = meta.modified() else {
            continue;
        };
        let age = now.duration_since(modified).unwrap_or_default();

        if age < BEST_EFFORT_RECENT {
            *newest = Some(newest.map_or(modified, |t| t.max(modified)));
        }

        let is_transcript = path
            .extension()
            .and_then(|s| s.to_str())
            .is_some_and(|ext| ext == "jsonl")
            && path
                .parent()
                .and_then(|p| p.file_name())
                .is_some_and(|n| n == "transcripts" || n == "emptyWindowChatSessions");

        // Finished chats often end on a dangling turn_start — only an open
        // tool call is a reliable "still working" signal past RECENT.
        if is_transcript && age < COPILOT_OPEN_TOOL_GRACE && !*open_tool {
            if copilot_transcript_has_open_tool(path) {
                *open_tool = true;
            }
        }
    }
}

/// Session / tool spill only — not codebase index DBs that touch while VS Code
/// sits idle with the Copilot extension loaded.
fn copilot_activity_file(path: &Path) -> bool {
    let parts: Vec<_> = path.components().map(|c| c.as_os_str()).collect();
    if parts
        .iter()
        .any(|p| *p == "transcripts" || *p == "emptyWindowChatSessions")
    {
        return path
            .extension()
            .and_then(|s| s.to_str())
            .is_some_and(|ext| ext == "jsonl" || ext == "json");
    }
    if parts.iter().any(|p| *p == "chat-session-resources") {
        return true;
    }
    if parts.iter().any(|p| *p == "copilot-terminal-output") {
        return true;
    }
    if parts.iter().any(|p| *p == "debug-logs") {
        return path
            .extension()
            .and_then(|s| s.to_str())
            .is_some_and(|ext| ext == "jsonl");
    }
    false
}

/// True when the transcript has a tool.execution_start without its complete.
fn copilot_transcript_has_open_tool(path: &Path) -> bool {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return false;
    };
    classify_copilot_open_tool(&raw)
}

fn classify_copilot_open_tool(raw: &str) -> bool {
    let mut open_tools: Vec<String> = Vec::new();

    for line in raw.lines() {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(type_str) = value.get("type").and_then(|v| v.as_str()) else {
            continue;
        };
        match type_str {
            "tool.execution_start" => {
                let id = value
                    .pointer("/data/toolCallId")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                open_tools.push(id);
            }
            "tool.execution_complete" => {
                let id = value
                    .pointer("/data/toolCallId")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if let Some(pos) = open_tools.iter().rposition(|t| t == id || t.is_empty()) {
                    open_tools.remove(pos);
                } else if !open_tools.is_empty() {
                    open_tools.pop();
                }
            }
            _ => {}
        }
    }

    !open_tools.is_empty()
}

/// HTTP hook ingest helpers used by the engine.
pub fn parse_hook_payload(body: &str) -> anyhow::Result<SessionEvent> {
    #[derive(Deserialize)]
    struct Payload {
        provider: Option<String>,
        kind: String,
        label: Option<String>,
    }
    let payload: Payload = serde_json::from_str(body)?;
    let provider = payload
        .provider
        .map(ProviderId::new)
        .unwrap_or(ProviderId::ClaudeCode);
    let kind = match payload.kind.as_str() {
        "busy" => SessionKind::Busy,
        "waiting_you" | "waiting" => SessionKind::WaitingYou,
        "idle" | "finished" => SessionKind::Idle,
        other => anyhow::bail!("unknown session kind: {other}"),
    };
    Ok(SessionEvent {
        provider,
        kind,
        label: payload.label,
    })
}

/// Convenience for tests / doctor.
pub fn summarize_sessions() -> HashMap<ProviderId, SessionKind> {
    let mut map = HashMap::new();
    for profile in profiles::claude_profiles() {
        let claude = match chats::read_claude_sessions(&profile.dir.join("sessions")) {
            Some(live) => summarize_claude(&live, &profile.id),
            None => detect_claude_session(&profile.dir, &profile.id),
        };
        map.insert(profile.id, claude.kind);
    }
    let opencode = crate::opencode::live_sessions();
    let kind = opencode
        .iter()
        .map(|session| session.kind)
        .max_by_key(|kind| match kind {
            SessionKind::WaitingYou => 2,
            SessionKind::Busy => 1,
            SessionKind::Idle => 0,
        })
        .unwrap_or(SessionKind::Idle);
    map.insert(ProviderId::OpenCode, kind);
    map.insert(ProviderId::Cursor, detect_cursor_session().kind);
    map.insert(ProviderId::Copilot, detect_copilot_session().kind);
    map
}

#[cfg(test)]
mod tests {
    use super::classify_copilot_open_tool;

    #[test]
    fn copilot_open_tool_counts_as_working() {
        let raw = r#"
{"type":"session.start","data":{},"timestamp":"2026-09-30T18:00:00Z"}
{"type":"assistant.turn_start","data":{"turnId":"1"},"timestamp":"2026-09-30T18:00:01Z"}
{"type":"tool.execution_start","data":{"toolCallId":"call_1","toolName":"bash"},"timestamp":"2026-09-30T18:00:02Z"}
"#;
        assert!(classify_copilot_open_tool(raw));
    }

    #[test]
    fn copilot_dangling_turn_start_alone_is_not_open_tool() {
        // Finished chats usually end on turn_start — must not keep Busy for minutes.
        let raw = r#"
{"type":"assistant.turn_start","data":{"turnId":"1"},"timestamp":"2026-09-30T18:00:01Z"}
{"type":"tool.execution_start","data":{"toolCallId":"call_1","toolName":"bash"},"timestamp":"2026-09-30T18:00:02Z"}
{"type":"tool.execution_complete","data":{"toolCallId":"call_1","success":true},"timestamp":"2026-09-30T18:00:05Z"}
{"type":"assistant.message","data":{"content":"done"},"timestamp":"2026-09-30T18:00:06Z"}
{"type":"assistant.turn_end","data":{"turnId":"1"},"timestamp":"2026-09-30T18:00:06Z"}
{"type":"assistant.turn_start","data":{"turnId":"2"},"timestamp":"2026-09-30T18:00:06Z"}
"#;
        assert!(!classify_copilot_open_tool(raw));
    }

    #[test]
    fn copilot_balanced_idle_tail_is_not_open_tool() {
        let raw = r#"
{"type":"assistant.turn_start","data":{"turnId":"1"},"timestamp":"2026-09-30T18:00:01Z"}
{"type":"assistant.message","data":{"content":"hi"},"timestamp":"2026-09-30T18:00:02Z"}
{"type":"assistant.turn_end","data":{"turnId":"1"},"timestamp":"2026-09-30T18:00:02Z"}
"#;
        assert!(!classify_copilot_open_tool(raw));
    }
}
