//! Wire protocol between the Omega Notch engine and any UI shell.
//!
//! Transport: newline-delimited JSON over a Unix domain socket
//! (`$XDG_RUNTIME_DIR/omega-notch.sock`).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderId {
    Cursor,
    ClaudeCode,
    ClaudeDesktop,
    Copilot,
    GrokBot,
    Codex,
    /// Reserved for a future browser extension.
    ClaudeWeb,
    ChatgptWeb,
    GeminiWeb,
}

impl ProviderId {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cursor => "cursor",
            Self::ClaudeCode => "claude_code",
            Self::ClaudeDesktop => "claude_desktop",
            Self::Copilot => "copilot",
            Self::GrokBot => "grok_bot",
            Self::Codex => "codex",
            Self::ClaudeWeb => "claude_web",
            Self::ChatgptWeb => "chatgpt_web",
            Self::GeminiWeb => "gemini_web",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Cursor => "Cursor",
            Self::ClaudeCode => "Claude Code",
            Self::ClaudeDesktop => "Claude Desktop",
            Self::Copilot => "GitHub Copilot",
            Self::GrokBot => "Grok Bot",
            Self::Codex => "Codex",
            Self::ClaudeWeb => "Claude Web",
            Self::ChatgptWeb => "ChatGPT",
            Self::GeminiWeb => "Gemini",
        }
    }

    pub fn mvp_providers() -> &'static [ProviderId] {
        &[
            Self::Cursor,
            Self::ClaudeCode,
            Self::ClaudeDesktop,
            Self::Copilot,
            Self::GrokBot,
            Self::Codex,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Fidelity {
    Official,
    Derived,
    Manual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadingStatus {
    Ok,
    Stale,
    NeedsAuth,
    Error,
    Disabled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageWindow {
    pub label: String,
    /// 0..=100 share already used.
    pub used_pct: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageReading {
    pub provider: ProviderId,
    pub display_name: String,
    pub fidelity: Fidelity,
    pub status: ReadingStatus,
    pub windows: Vec<UsageWindow>,
    pub fetched_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl UsageReading {
    pub fn headline_pct(&self) -> Option<f64> {
        self.windows.first().map(|w| w.used_pct)
    }

    pub fn needs_auth(provider: ProviderId, message: impl Into<String>) -> Self {
        Self {
            provider,
            display_name: provider.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::NeedsAuth,
            windows: vec![],
            fetched_at: Utc::now(),
            message: Some(message.into()),
        }
    }

    pub fn error(provider: ProviderId, message: impl Into<String>) -> Self {
        Self {
            provider,
            display_name: provider.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Error,
            windows: vec![],
            fetched_at: Utc::now(),
            message: Some(message.into()),
        }
    }

    pub fn disabled(provider: ProviderId) -> Self {
        Self {
            provider,
            display_name: provider.display_name().to_string(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Disabled,
            windows: vec![],
            fetched_at: Utc::now(),
            message: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionKind {
    Idle,
    Busy,
    WaitingYou,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub provider: ProviderId,
    pub kind: SessionKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub updated_at: DateTime<Utc>,
}

/// A provider's headline window passing a usage threshold (v5), to be
/// announced; see `limits`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LimitAlert {
    pub provider: ProviderId,
    pub display_name: String,
    /// The window's own name, such as "Current session".
    pub label: String,
    pub used_pct: f64,
    /// 80 or 100.
    pub threshold: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<DateTime<Utc>>,
}

/// Token counts as the vendor bills them. Cache reads and writes are kept
/// apart from fresh input because they dominate agent sessions.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenTotals {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

impl TokenTotals {
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_write
    }

    pub fn add(&mut self, other: &TokenTotals) {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
    }

    pub fn sub(&mut self, other: &TokenTotals) {
        self.input = self.input.saturating_sub(other.input);
        self.output = self.output.saturating_sub(other.output);
        self.cache_read = self.cache_read.saturating_sub(other.cache_read);
        self.cache_write = self.cache_write.saturating_sub(other.cache_write);
    }
}

/// One conversation, newest first in the snapshot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatSummary {
    pub provider: ProviderId,
    pub id: String,
    pub title: String,
    /// Folder name of the workspace the chat ran in.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Where it runs: "CLI", "VS Code", "Desktop", "Agent"…
    #[serde(skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
    pub state: SessionKind,
    /// A process still owns this chat.
    pub live: bool,
    pub updated_at: DateTime<Utc>,
    pub messages: u32,
    /// Lifetime tokens of the chat, when the provider records them locally.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<TokenTotals>,
    /// Prompt size of the latest turn, i.e. how full the context is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_pct: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines_added: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines_removed: Option<u64>,
    /// It stopped with a reply you have not looked at yet (v6, additive;
    /// see `seen.rs`).
    #[serde(default)]
    pub unread: bool,
    /// When you last typed a prompt in it. Engine-internal.
    #[serde(skip)]
    pub prompted_at: Option<DateTime<Utc>>,
    /// When its latest reply came. Engine-internal.
    #[serde(skip)]
    pub replied_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DayTokens {
    /// Local calendar day, `YYYY-MM-DD`.
    pub date: String,
    pub total: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelTokens {
    pub model: String,
    pub total: u64,
}

/// One persisted day for the dashboard chart (see `history.rs`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryPoint {
    pub provider: ProviderId,
    /// Local calendar day, `YYYY-MM-DD`.
    pub date: String,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub total: u64,
}

/// One model's tokens on one local day, split by kind. Engine-internal:
/// it feeds the persisted history, not the live snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DayModelTokens {
    /// Local calendar day, `YYYY-MM-DD`.
    pub date: String,
    pub model: String,
    pub tokens: TokenTotals,
}

/// One model on one persisted day for the dashboard, with its estimated cost.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelDayPoint {
    pub provider: ProviderId,
    /// Local calendar day, `YYYY-MM-DD`.
    pub date: String,
    pub model: String,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub total: u64,
    pub cost_usd: f64,
}

/// One session's tokens on one local day with one model. Engine-internal:
/// it feeds the persisted per-session history (see `history.rs`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionDayTokens {
    pub session_id: String,
    /// Local calendar day, `YYYY-MM-DD`.
    pub date: String,
    pub model: String,
    pub tokens: TokenTotals,
}

/// What a session is called and where it ran, kept with its history so the
/// dashboard can name a session the live scan no longer reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionMeta {
    pub session_id: String,
    pub title: String,
    pub project: Option<String>,
    pub cwd: Option<String>,
    pub surface: Option<String>,
    pub updated_at: DateTime<Utc>,
}

/// One model's share of a session over the dashboard range.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionModelCost {
    pub model: String,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub total: u64,
    pub cost_usd: f64,
}

/// One session's spend over the dashboard range, dearest first in the
/// dashboard (v6, additive). Subagents count towards the session that ran
/// them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionCost {
    pub provider: ProviderId,
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
    /// Last day in the range the session spent tokens, `YYYY-MM-DD`.
    pub last_date: String,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub total: u64,
    pub cost_usd: f64,
    /// Dearest first.
    pub models: Vec<SessionModelCost>,
}

/// Estimated spend for one model bucket today (see `pricing.rs`).
/// Always an estimate — vendors reprice without notice.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CostEstimate {
    pub provider: ProviderId,
    pub model: String,
    pub total: u64,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenStats {
    pub provider: ProviderId,
    pub today: TokenTotals,
    pub week: TokenTotals,
    /// Last seven local days, oldest first, today last.
    pub daily: Vec<DayTokens>,
    /// Today's tokens per model, largest first.
    pub models_today: Vec<ModelTokens>,
    /// Per-day, per-model split of `daily`, for the history. Not sent.
    #[serde(skip)]
    pub days_by_model: Vec<DayModelTokens>,
    /// The same days split by session too, for the history. Not sent.
    #[serde(skip)]
    pub session_days: Vec<SessionDayTokens>,
    /// Names of the sessions in `session_days`, when known. Not sent.
    #[serde(skip)]
    pub session_meta: Vec<SessionMeta>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Activity {
    pub chats: Vec<ChatSummary>,
    pub tokens: Vec<TokenStats>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello {
        client: String,
        version: u32,
    },
    Subscribe,
    Refresh {
        #[serde(default)]
        provider: Option<ProviderId>,
    },
    GetSnapshot,
    GetConfig,
    SetConfig {
        config: crate::config::AppConfig,
    },
    /// Start GitHub's device flow; progress comes back as `copilot_login`.
    CopilotSignIn,
    /// Bring the clicked chat to the front: its window, or a new one resuming it.
    OpenChat {
        provider: ProviderId,
        id: String,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        surface: Option<String>,
    },
    /// The window now in front (v6, macOS): the pid of the app that owns it
    /// and, with Accessibility, its title. A finished chat it shows counts
    /// as read.
    WindowFocused {
        pid: u32,
        #[serde(default)]
        title: Option<String>,
    },
    /// Dashboard history + cost estimates (v3). `days` clamps to 7..=90.
    GetDashboard {
        #[serde(default = "default_dashboard_days")]
        days: u32,
    },
    Ping,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum CopilotLogin {
    /// Waiting for the user to enter `user_code` at `verification_uri`.
    Pending {
        user_code: String,
        verification_uri: String,
        expires_at: DateTime<Utc>,
    },
    SignedIn,
    Failed {
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Hello {
        server: String,
        version: u32,
        protocol: u32,
    },
    Snapshot {
        readings: Vec<UsageReading>,
        sessions: Vec<SessionState>,
        chats: Vec<ChatSummary>,
        tokens: Vec<TokenStats>,
        config: crate::config::AppConfig,
    },
    ActivityUpdated {
        chats: Vec<ChatSummary>,
        tokens: Vec<TokenStats>,
    },
    UsageUpdated {
        reading: UsageReading,
    },
    SessionUpdated {
        session: SessionState,
    },
    SessionFinished {
        session: SessionState,
    },
    SessionWaiting {
        session: SessionState,
    },
    /// A usage threshold passed (v5, additive).
    LimitReached {
        limit: LimitAlert,
    },
    ConfigUpdated {
        config: crate::config::AppConfig,
    },
    Dashboard {
        points: Vec<HistoryPoint>,
        costs: Vec<CostEstimate>,
        total_usd: f64,
        /// Per-day, per-model history with estimated cost (v3, additive).
        #[serde(default)]
        models: Vec<ModelDayPoint>,
        /// The range's dearest sessions, with their models (v6, additive).
        #[serde(default)]
        sessions: Vec<SessionCost>,
    },
    CopilotLogin {
        login: CopilotLogin,
    },
    /// Sent back to the client that asked to open a chat, when picking its
    /// window is the client's job (macOS, v4, additive).
    RaiseWindow {
        pids: Vec<u32>,
        hints: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tty: Option<String>,
    },
    Pong,
    Error {
        message: String,
    },
}

/// Goes up only for a change an older client would misread: a message or
/// field removed or changed in meaning. Additions keep it (protocol/README.md).
pub const PROTOCOL_VERSION: u32 = 6;
pub const ENGINE_NAME: &str = "omega-notch-engine";

fn default_dashboard_days() -> u32 {
    30
}
