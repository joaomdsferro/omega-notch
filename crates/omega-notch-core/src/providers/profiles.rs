//! Accounts kept apart by directory.
//!
//! Claude Code and Codex both keep everything for one account under a single
//! directory: `~/.claude` and `~/.codex` by default, and `~/.claude-<slug>` /
//! `~/.codex-<slug>` for anyone who keeps a second login (work, a client).
//! A profile is the directory convention, not `CLAUDE_CONFIG_DIR` or
//! `CODEX_HOME`: the app is launched from a desktop session, so an alias's
//! variable never reaches it.
//!
//! The default account keeps the id it has always had (`claude_code`,
//! `codex`); every other one is `<base>-<slug>`, so saved readings, chats and
//! preferences survive.

use std::path::{Path, PathBuf};

use crate::protocol::ProviderId;

const CLAUDE_PREFIX: &str = ".claude";
const CODEX_PREFIX: &str = ".codex";

/// Directories Claude Code creates the first time it runs against one.
const CLAUDE_MARKERS: &[&str] = &[
    "sessions",
    "projects",
    "settings.json",
    "history.jsonl",
    ".claude.json",
];

/// What Codex leaves behind, signed in or not: a profile that has been signed
/// out still deserves a row explaining how to sign the account back in.
const CODEX_MARKERS: &[&str] = &[
    "auth.json",
    "config.toml",
    "sessions",
    "history.jsonl",
    "state_5.sqlite",
    "sqlite/codex-dev.db",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Profile {
    /// `claude_code` for the default, `claude_code-work` for the rest.
    pub id: ProviderId,
    /// The base provider's id.
    pub base: &'static str,
    pub slug: Option<String>,
    pub dir: PathBuf,
}

impl Profile {
    fn new(base: &'static str, slug: Option<String>, dir: PathBuf) -> Self {
        let id = match &slug {
            Some(slug) => ProviderId::new(format!("{base}-{slug}")),
            None => ProviderId::new(base),
        };
        Self {
            id,
            base,
            slug,
            dir,
        }
    }

    pub fn display_name(&self) -> String {
        let name = match self.base {
            id if id == ProviderId::ClaudeCode.as_str() => "Claude Code",
            _ => "Codex",
        };
        match &self.slug {
            Some(slug) => format!("{name} ({slug})"),
            None => name.to_string(),
        }
    }
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

pub fn claude_profiles() -> Vec<Profile> {
    claude_profiles_at(&home())
}

pub fn codex_profiles() -> Vec<Profile> {
    codex_profiles_at(&home())
}

pub fn claude_profiles_at(home: &Path) -> Vec<Profile> {
    discover(
        home,
        CLAUDE_PREFIX,
        ProviderId::ClaudeCode.as_str(),
        CLAUDE_MARKERS,
        true,
    )
}

pub fn codex_profiles_at(home: &Path) -> Vec<Profile> {
    discover(
        home,
        CODEX_PREFIX,
        ProviderId::Codex.as_str(),
        CODEX_MARKERS,
        false,
    )
}

/// The default account followed by every `.<base>-<slug>` that has been used,
/// slugs in alphabetical order so rings never swap places between launches.
fn discover(
    home: &Path,
    prefix: &str,
    base: &'static str,
    markers: &[&str],
    needs_credentials: bool,
) -> Vec<Profile> {
    let default_dir = home.join(prefix);
    let mut profiles = vec![Profile::new(base, None, default_dir)];

    let Ok(entries) = std::fs::read_dir(home) else {
        return profiles;
    };
    let mut extras = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(slug) = slug_from_directory(name, prefix) else {
            continue;
        };
        let dir = entry.path();
        if !dir.is_dir() || !markers.iter().any(|m| dir.join(m).exists()) {
            continue;
        }
        // Claude Code files a token under the account's own directory. A stray
        // `~/.claude-notes` with a settings file is not an account, and a ring
        // that says "sign in" for it could never be acted on.
        if needs_credentials && !dir.join(".credentials.json").exists() {
            continue;
        }
        extras.push(Profile::new(base, Some(slug), dir));
    }
    extras.sort_by(|a, b| a.slug.cmp(&b.slug));
    profiles.extend(extras);
    profiles
}

/// `.claude-work` → `work`. Anything else, including a bare `.claude` or the
/// `.claude.json` file beside it, is not a profile.
fn slug_from_directory(name: &str, prefix: &str) -> Option<String> {
    let slug = name.strip_prefix(prefix)?.strip_prefix('-')?;
    if slug.is_empty()
        || !slug
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return None;
    }
    Some(slug.to_string())
}

/// Whether the id names a Claude Code account, default or not.
pub fn is_claude(id: &ProviderId) -> bool {
    id.as_str() == ProviderId::ClaudeCode.as_str() || id.as_str().starts_with("claude_code-")
}

/// Whether the id names a Codex account, default or not.
pub fn is_codex(id: &ProviderId) -> bool {
    id.as_str() == ProviderId::Codex.as_str() || id.as_str().starts_with("codex-")
}

/// The profile a provider id names, default or not.
pub fn from_id(id: &ProviderId) -> Option<Profile> {
    if let Some(slug) = id.as_str().strip_prefix("claude_code-") {
        return valid_slug(slug).then(|| {
            Profile::new(
                ProviderId::ClaudeCode.as_str(),
                Some(slug.to_string()),
                home().join(format!("{CLAUDE_PREFIX}-{slug}")),
            )
        });
    }
    if let Some(slug) = id.as_str().strip_prefix("codex-") {
        return valid_slug(slug).then(|| {
            Profile::new(
                ProviderId::Codex.as_str(),
                Some(slug.to_string()),
                home().join(format!("{CODEX_PREFIX}-{slug}")),
            )
        });
    }
    None
}

fn valid_slug(slug: &str) -> bool {
    !slug.is_empty()
        && slug
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("omega-notch-profiles-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"{}").unwrap();
    }

    #[test]
    fn the_default_account_comes_first_and_keeps_its_id() {
        let home = scratch("default");
        let profiles = claude_profiles_at(&home);
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].id, ProviderId::ClaudeCode);
        assert_eq!(profiles[0].display_name(), "Claude Code");
        assert_eq!(profiles[0].dir, home.join(".claude"));
    }

    #[test]
    fn claude_profiles_need_a_directory_marker_and_a_token() {
        let home = scratch("claude");
        touch(&home.join(".claude-work/sessions/1.json"));
        touch(&home.join(".claude-work/.credentials.json"));
        touch(&home.join(".claude-notes/settings.json"));
        touch(&home.join(".claude-clients/.credentials.json"));
        touch(&home.join(".claude-deep/settings.json"));
        touch(&home.join(".claude-deep/.credentials.json"));

        let slugs: Vec<_> = claude_profiles_at(&home)
            .into_iter()
            .map(|p| p.id.as_str().to_string())
            .collect();
        assert_eq!(
            slugs,
            ["claude_code", "claude_code-deep", "claude_code-work"]
        );
    }

    #[test]
    fn codex_profiles_only_need_a_directory_marker() {
        let home = scratch("codex");
        touch(&home.join(".codex-work/auth.json"));
        touch(&home.join(".codex-old/history.jsonl"));
        touch(&home.join(".codex-notes/config.toml.bak"));

        let ids: Vec<_> = codex_profiles_at(&home)
            .into_iter()
            .map(|p| (p.id.as_str().to_string(), p.display_name()))
            .collect();
        assert_eq!(
            ids,
            [
                ("codex".to_string(), "Codex".to_string()),
                ("codex-old".to_string(), "Codex (old)".to_string()),
                ("codex-work".to_string(), "Codex (work)".to_string()),
            ]
        );
    }

    #[test]
    fn ids_round_trip_to_the_same_directory() {
        let profile = from_id(&ProviderId::new("claude_code-work")).unwrap();
        assert_eq!(profile.base, "claude_code");
        assert_eq!(profile.slug.as_deref(), Some("work"));
        assert!(profile.dir.ends_with(".claude-work"));
        assert_eq!(profile.id, ProviderId::new("claude_code-work"));

        let profile = from_id(&ProviderId::new("codex-client")).unwrap();
        assert_eq!(profile.dir, home().join(".codex-client"));

        assert!(from_id(&ProviderId::Codex).is_none());
        assert!(from_id(&ProviderId::new("claude_code-")).is_none());
        assert!(from_id(&ProviderId::new("claude_code-a/b")).is_none());
    }

    #[test]
    fn a_bare_prefix_is_not_a_slug() {
        assert_eq!(
            slug_from_directory(".claude-work", ".claude").as_deref(),
            Some("work")
        );
        assert_eq!(slug_from_directory(".claude", ".claude"), None);
        assert_eq!(slug_from_directory(".claude.json", ".claude"), None);
        assert_eq!(slug_from_directory(".claude-", ".claude"), None);
        assert_eq!(slug_from_directory(".claude-a b", ".claude"), None);
    }
}
