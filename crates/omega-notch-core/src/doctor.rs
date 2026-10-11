use std::fmt::Write as _;

use crate::config::AppConfig;
use crate::paths;
use crate::protocol::ProviderId;
use crate::providers;
use crate::sessions;

pub async fn run_doctor() -> String {
    let mut out = String::new();
    let _ = writeln!(out, "Omega Notch doctor");
    let _ = writeln!(out, "=================");
    let _ = writeln!(out, "socket: {}", paths::socket_path().display());
    let _ = writeln!(out, "config: {}", paths::config_file().display());
    let _ = writeln!(out, "data:   {}", paths::app_data_dir().display());
    let _ = writeln!(out);

    let config = AppConfig::load();
    let _ = writeln!(
        out,
        "edge={:?} size={:?} peek={}s",
        config.edge, config.size, config.peek_seconds
    );
    let _ = writeln!(out);

    for id in ProviderId::mvp_providers() {
        let enabled = config.provider_enabled(*id);
        let _ = writeln!(out, "[{}] enabled={enabled}", id.display_name());
        match id {
            ProviderId::Cursor => {
                let db = paths::cursor_state_db();
                let _ = writeln!(out, "  state.vscdb: {} exists={}", db.display(), db.exists());
            }
            ProviderId::ClaudeCode => {
                let creds = paths::claude_credentials();
                let _ = writeln!(
                    out,
                    "  credentials: {} exists={}",
                    creds.display(),
                    creds.exists()
                );
                let projects = paths::claude_projects();
                let _ = writeln!(
                    out,
                    "  projects: {} exists={}",
                    projects.display(),
                    projects.exists()
                );
            }
            ProviderId::ClaudeDesktop => {
                let dir = paths::claude_desktop_dir();
                let _ = writeln!(out, "  desktop: {} exists={}", dir.display(), dir.exists());
            }
            ProviderId::Copilot => {
                let dir = paths::github_copilot_dir();
                let _ = writeln!(out, "  github-copilot: {} exists={}", dir.display(), dir.exists());
                let opencode = paths::opencode_auth();
                let _ = writeln!(
                    out,
                    "  opencode auth: {} exists={}",
                    opencode.display(),
                    opencode.exists()
                );
            }
            ProviderId::GrokBot => {
                let dir = paths::grok_bot_dir();
                let _ = writeln!(out, "  grokbot: {} exists={}", dir.display(), dir.exists());
                let db = paths::cursor_state_db();
                let _ = writeln!(out, "  cursor sign-in: {} exists={}", db.display(), db.exists());
            }
            ProviderId::Codex => {
                let auth = paths::codex_auth();
                let _ = writeln!(out, "  codex auth: {} exists={}", auth.display(), auth.exists());
            }
            _ => {}
        }

        if enabled {
            let reading = providers::fetch_provider(*id, &config).await;
            let headline = reading
                .headline_pct()
                .map(|p| format!("{p:.1}%"))
                .unwrap_or_else(|| "—".into());
            let _ = writeln!(
                out,
                "  status={:?} fidelity={:?} headline={headline}",
                reading.status, reading.fidelity
            );
            if let Some(msg) = &reading.message {
                let _ = writeln!(out, "  message={msg}");
            }
            for w in &reading.windows {
                let reset = w
                    .resets_at
                    .map(|t| t.to_rfc3339())
                    .unwrap_or_else(|| "—".into());
                let _ = writeln!(
                    out,
                    "  window {:?} {:.1}% resets {}",
                    w.label, w.used_pct, reset
                );
            }
        }
        let _ = writeln!(out);
    }

    let sessions = sessions::summarize_sessions();
    let _ = writeln!(out, "Sessions");
    for (id, kind) in sessions {
        let _ = writeln!(out, "  {} -> {:?}", id.display_name(), kind);
    }

    let activity = crate::chats::ActivityIndex::new().scan(&config);
    let _ = writeln!(out);
    let _ = writeln!(out, "Tokens");
    for stats in &activity.tokens {
        let _ = writeln!(
            out,
            "  {} today={} (in {} · out {} · cache read {} · cache write {}) week={}",
            stats.provider.display_name(),
            stats.today.total(),
            stats.today.input,
            stats.today.output,
            stats.today.cache_read,
            stats.today.cache_write,
            stats.week.total()
        );
    }
    let _ = writeln!(out);
    let _ = writeln!(out, "Recent chats");
    for chat in &activity.chats {
        let tokens = chat
            .tokens
            .map(|t| t.total().to_string())
            .unwrap_or_else(|| "—".into());
        let _ = writeln!(
            out,
            "  [{}] {:?} {} · {} · tokens={tokens}",
            chat.provider.display_name(),
            chat.state,
            chat.title,
            chat.project.as_deref().unwrap_or("—"),
        );
    }

    out
}
