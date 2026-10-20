mod amp;
mod apify;
mod claude_code;
mod claude_desktop;
mod codex;
mod command_code;
mod copilot;
mod cursor;
mod devin;
mod glm;
mod grok;
mod grok_bot;
mod kilo;
mod kimi;
mod kiro;
mod opencode;
pub mod profiles;
mod traits;

pub use amp::AmpProvider;
pub use apify::ApifyProvider;
pub use claude_code::ClaudeCodeProvider;
pub use claude_desktop::ClaudeDesktopProvider;
pub use codex::CodexProvider;
pub use command_code::CommandCodeProvider;
pub use copilot::CopilotProvider;
pub use cursor::{token_activity as cursor_token_activity, CursorProvider};
pub use devin::DevinProvider;
pub use glm::GlmProvider;
pub use grok::GrokProvider;
pub use grok_bot::GrokBotProvider;
pub use kilo::KiloProvider;
pub use kimi::KimiProvider;
pub use kiro::KiroProvider;
pub use opencode::OpenCodeProvider;
pub use traits::{Provider, ProviderError};

use std::borrow::Cow;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;

use crate::config::AppConfig;
use crate::paths;
use crate::protocol::{ProviderId, UsageReading};

pub type FetchFuture =
    Pin<Box<dyn Future<Output = Result<UsageReading, ProviderError>> + Send + 'static>>;

/// Everything the engine and its shells need to know about one provider.
/// Adding a provider is a new entry here; no match on the id needs to grow.
#[derive(Clone)]
pub struct ProviderDescriptor {
    id: ProviderId,
    /// A `Cow` because a profile discovered on disk is named `Claude Code
    /// (work)`: the label only exists at runtime.
    display_name: Cow<'static, str>,
    /// Whether the tool has left anything on this machine: its folder, its
    /// sign-in or its binary. Only looks at the disk, never the network.
    detect: fn() -> bool,
    fetch: fn() -> FetchFuture,
}

impl ProviderDescriptor {
    const fn new(
        id: ProviderId,
        display_name: &'static str,
        detect: fn() -> bool,
        fetch: fn() -> FetchFuture,
    ) -> Self {
        Self {
            id,
            display_name: Cow::Borrowed(display_name),
            detect,
            fetch,
        }
    }

    /// A profile is only listed because its folder was found.
    fn for_profile(id: ProviderId, display_name: String, base: &Self) -> Self {
        Self {
            id,
            display_name: Cow::Owned(display_name),
            detect: || true,
            fetch: base.fetch,
        }
    }

    pub fn id(&self) -> &ProviderId {
        &self.id
    }

    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    pub fn detected(&self) -> bool {
        (self.detect)()
    }
}

/// The folder a file would sit in exists: the tool is installed even when
/// it is not signed in yet.
fn folder_of(file: PathBuf) -> bool {
    file.parent().is_some_and(Path::is_dir)
}

/// The providers this build can fetch, in the order shells show them.
pub static PROVIDERS: &[ProviderDescriptor] = &[
    ProviderDescriptor::new(
        ProviderId::Cursor,
        "Cursor",
        || paths::cursor_state_db().exists(),
        || Box::pin(CursorProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::ClaudeCode,
        "Claude Code",
        || paths::claude_home().is_dir(),
        || Box::pin(ClaudeCodeProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::ClaudeDesktop,
        "Claude Desktop",
        || paths::claude_desktop_dir().is_dir(),
        || Box::pin(ClaudeDesktopProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::Copilot,
        "GitHub Copilot",
        copilot::detected,
        || Box::pin(CopilotProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::GrokBot,
        "Grok Bot",
        || paths::grok_bot_dir().is_dir(),
        || Box::pin(GrokBotProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::Codex,
        "Codex",
        || paths::codex_home().is_dir(),
        || Box::pin(CodexProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::OpenCode,
        "OpenCode",
        || paths::opencode_dir().is_dir(),
        || Box::pin(OpenCodeProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::Kimi,
        "Kimi",
        || paths::kimi_home().is_dir(),
        || Box::pin(KimiProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::Grok,
        "Grok",
        || folder_of(paths::grok_auth()),
        || Box::pin(GrokProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::Apify,
        "Apify",
        || folder_of(paths::apify_auth()),
        || Box::pin(ApifyProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::Devin,
        "Devin",
        || folder_of(paths::devin_desktop_db()) || folder_of(paths::devin_cli_credentials()),
        || Box::pin(DevinProvider.fetch()),
    ),
    ProviderDescriptor::new(
        ProviderId::Amp,
        "Amp",
        || folder_of(paths::amp_secrets()),
        || Box::pin(AmpProvider.fetch()),
    ),
    ProviderDescriptor::new(ProviderId::Kiro, "Kiro", kiro::detected, || {
        Box::pin(KiroProvider.fetch())
    }),
    ProviderDescriptor::new(
        ProviderId::Kilo,
        "Kilo",
        || folder_of(paths::kilo_auth()),
        || Box::pin(KiloProvider.fetch()),
    ),
    ProviderDescriptor::new(ProviderId::Glm, "GLM", glm::detected, || {
        Box::pin(GlmProvider.fetch())
    }),
    ProviderDescriptor::new(
        ProviderId::CommandCode,
        "Command Code",
        || folder_of(paths::command_code_auth()),
        || Box::pin(CommandCodeProvider.fetch()),
    ),
];

/// Whether a provider is on this machine. An account is, since it is only
/// listed once its folder is found; an id this build does not know is not.
pub fn detected(id: &ProviderId) -> bool {
    descriptor(id).is_some_and(|provider| provider.detected())
}

pub fn descriptor(id: &ProviderId) -> Option<ProviderDescriptor> {
    if let Some(provider) = PROVIDERS.iter().find(|provider| provider.id == *id) {
        return Some(provider.clone());
    }
    let profile = profiles::from_id(id)?;
    let base = PROVIDERS
        .iter()
        .find(|provider| provider.id.as_str() == profile.base)?;
    Some(ProviderDescriptor::for_profile(
        id.clone(),
        profile.display_name(),
        base,
    ))
}

/// The static providers plus the Claude Code and Codex accounts found on disk,
/// each right after its base provider. Every list the shells see comes from
/// here, so a profile needs no entry of its own.
pub fn catalog() -> Vec<ProviderDescriptor> {
    let mut out = Vec::with_capacity(PROVIDERS.len() + 2);
    for provider in PROVIDERS {
        out.push(provider.clone());
        let found = match provider.id.as_str() {
            "claude_code" => profiles::claude_profiles(),
            "codex" => profiles::codex_profiles(),
            _ => continue,
        };
        out.extend(
            found
                .into_iter()
                .filter(|profile| profile.slug.is_some())
                .map(|profile| {
                    ProviderDescriptor::for_profile(
                        profile.id.clone(),
                        profile.display_name(),
                        provider,
                    )
                }),
        );
    }
    out
}

pub async fn fetch_provider(id: ProviderId, config: &AppConfig) -> UsageReading {
    let profile = profiles::from_id(&id);
    // Switching a base provider off takes its accounts with it.
    let base_on = profile
        .as_ref()
        .is_none_or(|profile| config.provider_enabled(&ProviderId::new(profile.base)));
    if !config.provider_enabled(&id) || !base_on {
        return UsageReading::disabled(id);
    }
    let result = if let Some(profile) = profile {
        match profile.base {
            base if base == ProviderId::ClaudeCode.as_str() => {
                ClaudeCodeProvider::fetch_profile(&profile).await
            }
            _ => CodexProvider::fetch_profile(&profile).await,
        }
    } else {
        let Some(provider) = descriptor(&id) else {
            return UsageReading::disabled(id);
        };
        (provider.fetch)().await
    };

    match result {
        Ok(reading) => reading,
        Err(ProviderError::NeedsAuth(msg)) => UsageReading::needs_auth(id, msg),
        Err(ProviderError::Unsupported(_)) => UsageReading::disabled(id),
        Err(err) => UsageReading::error(id, err.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_ids_are_unique_and_looked_up_by_string() {
        let mut seen = std::collections::HashSet::new();
        for provider in PROVIDERS {
            assert!(seen.insert(provider.id().as_str()));
        }
        assert_eq!(PROVIDERS.len(), 16);
        assert_eq!(
            descriptor(&ProviderId::OpenCode).map(|p| p.display_name().to_string()),
            Some("OpenCode".to_string())
        );
        assert_eq!(
            descriptor(&ProviderId::new("claude_code")).map(|p| p.display_name().to_string()),
            Some("Claude Code".to_string())
        );
        assert!(descriptor(&ProviderId::new("future_tool")).is_none());
    }

    #[test]
    fn a_profile_id_resolves_to_its_base_provider() {
        let profile = descriptor(&ProviderId::new("claude_code-work")).unwrap();
        assert_eq!(profile.id().as_str(), "claude_code-work");
        assert_eq!(profile.display_name(), "Claude Code (work)");

        let profile = descriptor(&ProviderId::new("codex-client")).unwrap();
        assert_eq!(profile.display_name(), "Codex (client)");

        assert!(descriptor(&ProviderId::new("cursor-work")).is_none());
    }
}
