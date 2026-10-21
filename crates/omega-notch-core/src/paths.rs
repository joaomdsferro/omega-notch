use std::path::{Path, PathBuf};

/// The user's config folder: `~/.config` on Linux,
/// `~/Library/Application Support` on macOS.
pub fn config_home() -> PathBuf {
    dirs::config_dir().unwrap_or_else(|| PathBuf::from(".").join(".config"))
}

/// The user's data folder: `~/.local/share` on Linux,
/// `~/Library/Application Support` on macOS.
pub fn data_home() -> PathBuf {
    dirs::data_dir().unwrap_or_else(|| PathBuf::from(".").join(".local/share"))
}

/// Where the socket and other per-session files go. On Linux that is
/// `$XDG_RUNTIME_DIR`. macOS has no such folder, and `$TMPDIR` is not set for
/// every way the engine can be started, so it uses the app's own data folder,
/// which the engine keeps private.
pub fn runtime_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        return app_data_dir();
    }
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
}

/// Creates `dir` if needed and makes it readable by its owner only: it holds
/// the socket and sign-in tokens.
pub fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

pub fn app_config_dir() -> PathBuf {
    config_home().join("omega-notch")
}

pub fn app_data_dir() -> PathBuf {
    data_home().join("omega-notch")
}

/// Moves the config and data folders from the app's old name (Mega Notch)
/// to the new one, once, so settings and the Copilot sign-in carry over.
pub fn migrate_legacy_dirs() {
    for (base, new_dir) in [
        (config_home(), app_config_dir()),
        (data_home(), app_data_dir()),
    ] {
        let old_dir = base.join("mega-notch");
        if old_dir.is_dir() && !new_dir.exists() {
            if let Err(err) = std::fs::rename(&old_dir, &new_dir) {
                tracing::warn!(error = %err, from = %old_dir.display(), "could not move the old folder");
            }
        }
    }
}

pub fn config_file() -> PathBuf {
    app_config_dir().join("config.json")
}

pub fn socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("OMEGA_NOTCH_SOCKET").filter(|p| !p.is_empty()) {
        return PathBuf::from(path);
    }
    runtime_dir().join("omega-notch.sock")
}

pub fn cursor_state_db() -> PathBuf {
    config_home().join("Cursor/User/globalStorage/state.vscdb")
}

/// Where Claude Code keeps its sign-in on Linux. On macOS it is in the login
/// Keychain instead, under [`CLAUDE_KEYCHAIN_SERVICE`].
pub fn claude_credentials() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude/.credentials.json")
}

pub const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";

pub fn claude_home() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude")
}

pub fn claude_projects() -> PathBuf {
    claude_home().join("projects")
}

pub fn claude_sessions() -> PathBuf {
    claude_home().join("sessions")
}

pub fn claude_desktop_dir() -> PathBuf {
    config_home().join("Claude")
}

pub fn claude_desktop_usage_history() -> PathBuf {
    claude_desktop_dir().join("plan-usage-history.json")
}

/// Grok Bot's own state directory.
pub fn grok_bot_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".grokbot")
}

/// Grok Bot's local sand store, where its bots' roster and transcripts live
/// as one blob per base32-encoded key.
pub fn grok_bot_sand_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("Library/Application Support/Grok Bot/sand-client-persistence")
    }
    #[cfg(not(target_os = "macos"))]
    {
        config_home().join("Grok Bot/sand-client-persistence")
    }
}

/// Codex's home (CLI, IDE extension and desktop app share it).
pub fn codex_home() -> PathBuf {
    if let Some(home) = std::env::var_os("CODEX_HOME").filter(|p| !p.is_empty()) {
        return PathBuf::from(home);
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".codex")
}

/// Codex's ChatGPT sign-in.
pub fn codex_auth() -> PathBuf {
    codex_home().join("auth.json")
}

/// Codex's recent-thread index (`id`, `thread_name`, `updated_at`).
pub fn codex_session_index() -> PathBuf {
    codex_home().join("session_index.jsonl")
}

/// Codex rollout transcripts, under `YYYY/MM/DD/rollout-*.jsonl`.
pub fn codex_sessions_dir() -> PathBuf {
    codex_home().join("sessions")
}

/// Where the Copilot editor plugins (Neovim, JetBrains, Xcode…) keep their
/// GitHub OAuth token, as `apps.json` or the older `hosts.json`.
/// They use `~/.config` on macOS too, not `~/Library/Application Support`.
pub fn github_copilot_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        return home().join(".config/github-copilot");
    }
    config_home().join("github-copilot")
}

/// opencode's data directory: its credential store, its SQLite database of
/// sessions and messages, and its logs.
/// opencode uses `~/.local/share` on macOS too.
pub fn opencode_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        return home().join(".local/share/opencode");
    }
    data_home().join("opencode")
}

/// opencode's credential store; its `github-copilot` entry holds the same
/// GitHub OAuth token as its `refresh` field.
pub fn opencode_auth() -> PathBuf {
    opencode_dir().join("auth.json")
}

/// opencode's SQLite store: sessions, messages and their token counts,
/// kept per provider and model.
pub fn opencode_db() -> PathBuf {
    opencode_dir().join("opencode.db")
}

/// Kimi Code CLI's data root; `KIMI_CODE_HOME` moves it.
pub fn kimi_home() -> PathBuf {
    if let Some(root) = std::env::var_os("KIMI_CODE_HOME").filter(|p| !p.is_empty()) {
        return PathBuf::from(root);
    }
    home().join(".kimi-code")
}

/// Kimi Code CLI's OAuth session.
pub fn kimi_credentials() -> PathBuf {
    kimi_home().join("credentials/kimi-code.json")
}

/// Grok CLI's session: the access token, and the refresh token and client id
/// it renews with.
pub fn grok_auth() -> PathBuf {
    home().join(".grok/auth.json")
}

/// Where the Amp CLI keeps its API key.
pub fn amp_secrets() -> PathBuf {
    home().join(".local/share/amp/secrets.json")
}

/// Where `apify login` keeps its session.
pub fn apify_auth() -> PathBuf {
    home().join(".apify/auth.json")
}

/// Devin Desktop's global-storage database, where its sign-in lives.
pub fn devin_desktop_db() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home().join("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }
    #[cfg(not(target_os = "macos"))]
    {
        config_home().join("Devin/User/globalStorage/state.vscdb")
    }
}

/// The credentials `devin auth login` writes, used when Devin Desktop is not
/// installed. Devin keeps them under `~/.local/share` on macOS too.
pub fn devin_cli_credentials() -> PathBuf {
    home().join(".local/share/devin/credentials.toml")
}

/// The Command Code desktop app's sign-in.
pub fn command_code_auth() -> PathBuf {
    home().join(".commandcode/auth.json")
}

/// The Kilo CLI's account, shared by the VS Code extension and JetBrains
/// plugin.
pub fn kilo_auth() -> PathBuf {
    home().join(".local/share/kilo/auth.json")
}

/// Claude Code's settings file, where a GLM Coding Plan key is often pointed
/// at a Z.ai base URL.
pub fn claude_settings() -> PathBuf {
    claude_home().join("settings.json")
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// The GitHub token from signing in to Copilot through the notch.
pub fn copilot_token_file() -> PathBuf {
    app_data_dir().join("copilot.json")
}

/// VS Code product config roots that may hold Copilot Chat storage.
///
/// Covers the stable, Insiders, OSS, and VSCodium layouts under the config
/// folder.
pub fn vscode_product_dirs() -> Vec<PathBuf> {
    let config = config_home();
    ["Code", "Code - Insiders", "Code - OSS", "VSCodium"]
        .into_iter()
        .map(|name| config.join(name))
        .filter(|p| p.is_dir())
        .collect()
}
