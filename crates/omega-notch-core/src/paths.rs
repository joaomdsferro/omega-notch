use std::path::PathBuf;

pub fn xdg_config_home() -> PathBuf {
    dirs::config_dir().unwrap_or_else(|| PathBuf::from(".").join(".config"))
}

pub fn xdg_data_home() -> PathBuf {
    dirs::data_dir().unwrap_or_else(|| PathBuf::from(".").join(".local/share"))
}

pub fn xdg_runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir())
}

pub fn app_config_dir() -> PathBuf {
    xdg_config_home().join("omega-notch")
}

pub fn app_data_dir() -> PathBuf {
    xdg_data_home().join("omega-notch")
}

/// Moves the config and data folders from the app's old name (Mega Notch)
/// to the new one, once, so settings and the Copilot sign-in carry over.
pub fn migrate_legacy_dirs() {
    for (base, new_dir) in [
        (xdg_config_home(), app_config_dir()),
        (xdg_data_home(), app_data_dir()),
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
    xdg_runtime_dir().join("omega-notch.sock")
}

pub fn cursor_state_db() -> PathBuf {
    xdg_config_home()
        .join("Cursor/User/globalStorage/state.vscdb")
}

pub fn claude_credentials() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude/.credentials.json")
}

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
    xdg_config_home().join("Claude")
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

/// Where the Copilot editor plugins (Neovim, JetBrains, Xcode…) keep their
/// GitHub OAuth token, as `apps.json` or the older `hosts.json`.
pub fn github_copilot_dir() -> PathBuf {
    xdg_config_home().join("github-copilot")
}

/// opencode's credential store; its `github-copilot` entry holds the same
/// GitHub OAuth token as its `refresh` field.
pub fn opencode_auth() -> PathBuf {
    xdg_data_home().join("opencode/auth.json")
}

/// The GitHub token from signing in to Copilot through the notch.
pub fn copilot_token_file() -> PathBuf {
    app_data_dir().join("copilot.json")
}

/// VS Code product config roots that may hold Copilot Chat storage.
///
/// Covers the stable, Insiders, OSS, and VSCodium layouts under XDG config.
pub fn vscode_product_dirs() -> Vec<PathBuf> {
    let config = xdg_config_home();
    [
        "Code",
        "Code - Insiders",
        "Code - OSS",
        "VSCodium",
    ]
    .into_iter()
    .map(|name| config.join(name))
    .filter(|p| p.is_dir())
    .collect()
}
