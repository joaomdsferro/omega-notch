//! One JSON file per server message, in `protocol/fixtures/`, exactly as the
//! engine writes it. The macOS shell's tests decode every file, so a change on
//! either side of the protocol that the other cannot read fails a test.
//!
//! After an intended change to a message, rewrite the files with
//! `OMEGA_NOTCH_WRITE_FIXTURES=1 cargo test -p omega-notch-core --test protocol_fixtures`.

use std::path::PathBuf;

use chrono::{TimeZone, Utc};
use omega_notch_core::config::AppConfig;
use omega_notch_core::protocol::*;

fn at(h: u32, m: u32) -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 1, h, m, 0).unwrap()
}

fn totals() -> TokenTotals {
    TokenTotals {
        input: 412,
        output: 28247,
        cache_read: 3357968,
        cache_write: 128178,
    }
}

fn reading() -> UsageReading {
    UsageReading {
        provider: ProviderId::ClaudeCode,
        display_name: "Claude Code".into(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows: vec![
            UsageWindow {
                label: "Current session".into(),
                used_pct: 45.0,
                resets_at: Some(at(18, 50)),
            },
            UsageWindow {
                label: "Weekly limit".into(),
                used_pct: 55.5,
                resets_at: None,
            },
        ],
        fetched_at: at(14, 42),
        message: None,
    }
}

fn session(kind: SessionKind) -> SessionState {
    SessionState {
        provider: ProviderId::ClaudeCode,
        kind,
        label: Some("omega-notch".into()),
        updated_at: at(14, 42),
    }
}

fn chat() -> ChatSummary {
    ChatSummary {
        provider: ProviderId::ClaudeCode,
        id: "5073f281-1cf8-48a8-9c37-42d7aae21f83".into(),
        title: "Sidebar resize performance".into(),
        project: Some("omega-zap".into()),
        cwd: Some("/home/me/omega-zap".into()),
        model: Some("Opus 5.5".into()),
        surface: Some("VS Code".into()),
        state: SessionKind::Busy,
        live: true,
        updated_at: at(14, 42),
        messages: 12,
        tokens: Some(totals()),
        context_tokens: Some(151320),
        context_pct: Some(75.7),
        lines_added: Some(120),
        lines_removed: Some(8),
        unread: true,
        prompted_at: None,
        replied_at: None,
    }
}

fn stats() -> TokenStats {
    TokenStats {
        provider: ProviderId::ClaudeCode,
        today: totals(),
        week: totals(),
        daily: vec![DayTokens {
            date: "2026-10-01".into(),
            total: 3514805,
        }],
        models_today: vec![ModelTokens {
            model: "Opus 5.5".into(),
            total: 3514805,
        }],
        days_by_model: vec![],
        session_days: vec![],
        session_meta: vec![],
    }
}

/// The default, with the one field that differs between platforms pinned.
fn config() -> AppConfig {
    let mut config = AppConfig::default();
    config.edge = omega_notch_core::config::Edge::Right;
    config
}

fn messages() -> Vec<(&'static str, ServerMessage)> {
    vec![
        (
            "hello",
            ServerMessage::Hello {
                server: ENGINE_NAME.into(),
                version: 1,
                protocol: PROTOCOL_VERSION,
            },
        ),
        (
            "snapshot",
            ServerMessage::Snapshot {
                readings: vec![reading()],
                sessions: vec![session(SessionKind::Busy)],
                chats: vec![chat()],
                tokens: vec![stats()],
                config: config(),
            },
        ),
        (
            "activity_updated",
            ServerMessage::ActivityUpdated {
                chats: vec![chat()],
                tokens: vec![stats()],
            },
        ),
        (
            "usage_updated",
            ServerMessage::UsageUpdated { reading: reading() },
        ),
        (
            "session_updated",
            ServerMessage::SessionUpdated {
                session: session(SessionKind::Idle),
            },
        ),
        (
            "session_finished",
            ServerMessage::SessionFinished {
                session: session(SessionKind::Idle),
            },
        ),
        (
            "session_waiting",
            ServerMessage::SessionWaiting {
                session: session(SessionKind::WaitingYou),
            },
        ),
        (
            "limit_reached",
            ServerMessage::LimitReached {
                limit: LimitAlert {
                    provider: ProviderId::ClaudeCode,
                    display_name: "Claude Code".into(),
                    label: "Current session".into(),
                    used_pct: 81.5,
                    threshold: 80,
                    resets_at: Some(at(18, 50)),
                },
            },
        ),
        (
            "config_updated",
            ServerMessage::ConfigUpdated { config: config() },
        ),
        (
            "dashboard",
            ServerMessage::Dashboard {
                points: vec![HistoryPoint {
                    provider: ProviderId::ClaudeCode,
                    date: "2026-10-01".into(),
                    input: 412,
                    output: 28247,
                    cache_read: 3357968,
                    cache_write: 128178,
                    total: 3514805,
                }],
                costs: vec![CostEstimate {
                    provider: ProviderId::ClaudeCode,
                    model: "Opus 5.5".into(),
                    total: 3514805,
                    cost_usd: 1.27,
                }],
                total_usd: 1.27,
                models: vec![ModelDayPoint {
                    provider: ProviderId::ClaudeCode,
                    date: "2026-10-01".into(),
                    model: "Opus 5.5".into(),
                    input: 412,
                    output: 28247,
                    cache_read: 3357968,
                    cache_write: 128178,
                    total: 3514805,
                    cost_usd: 1.27,
                }],
                sessions: vec![SessionCost {
                    provider: ProviderId::ClaudeCode,
                    id: "3f1c9a52-5d0e-4c43-9a8e-1b2f6f0a7d11".into(),
                    title: "Sidebar resize performance".into(),
                    project: Some("omega-zap".into()),
                    cwd: Some("/home/me/omega-zap".into()),
                    surface: Some("VS Code".into()),
                    last_date: "2026-10-01".into(),
                    input: 412,
                    output: 28247,
                    cache_read: 3357968,
                    cache_write: 128178,
                    total: 3514805,
                    cost_usd: 1.27,
                    models: vec![SessionModelCost {
                        model: "Opus 5.5".into(),
                        input: 412,
                        output: 28247,
                        cache_read: 3357968,
                        cache_write: 128178,
                        total: 3514805,
                        cost_usd: 1.27,
                    }],
                }],
            },
        ),
        (
            "copilot_login",
            ServerMessage::CopilotLogin {
                login: CopilotLogin::Pending {
                    user_code: "ABCD-1234".into(),
                    verification_uri: "https://github.com/login/device".into(),
                    expires_at: at(15, 0),
                },
            },
        ),
        (
            "raise_window",
            ServerMessage::RaiseWindow {
                pids: vec![4242, 4100, 1],
                hints: vec!["omega-notch".into(), "Sidebar resize performance".into()],
                tty: Some("/dev/ttys003".into()),
            },
        ),
        ("pong", ServerMessage::Pong),
        (
            "error",
            ServerMessage::Error {
                message: "bad client message".into(),
            },
        ),
    ]
}

#[test]
fn fixtures_match_what_the_engine_writes() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../protocol/fixtures");
    let write = std::env::var_os("OMEGA_NOTCH_WRITE_FIXTURES").is_some();
    if write {
        std::fs::create_dir_all(&dir).unwrap();
    }
    for (name, message) in messages() {
        let json = serde_json::to_string_pretty(&message).unwrap() + "\n";
        let path = dir.join(format!("{name}.json"));
        if write {
            std::fs::write(&path, &json).unwrap();
            continue;
        }
        let kept = std::fs::read_to_string(&path).unwrap_or_default();
        assert_eq!(
            kept,
            json,
            "{} is out of date; see this file's header",
            path.display()
        );
    }
}
