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
mod traits;

pub use amp::AmpProvider;
pub use apify::ApifyProvider;
pub use claude_code::ClaudeCodeProvider;
pub use claude_desktop::ClaudeDesktopProvider;
pub use codex::CodexProvider;
pub use command_code::CommandCodeProvider;
pub use copilot::CopilotProvider;
pub use cursor::CursorProvider;
pub use devin::DevinProvider;
pub use glm::GlmProvider;
pub use grok::GrokProvider;
pub use grok_bot::GrokBotProvider;
pub use kilo::KiloProvider;
pub use kimi::KimiProvider;
pub use kiro::KiroProvider;
pub use opencode::OpenCodeProvider;
pub use traits::{Provider, ProviderError};

use std::future::Future;
use std::pin::Pin;

use crate::config::AppConfig;
use crate::protocol::{ProviderId, UsageReading};

pub type FetchFuture =
    Pin<Box<dyn Future<Output = Result<UsageReading, ProviderError>> + Send + 'static>>;

/// Everything the engine and its shells need to know about one provider.
/// Adding a provider is a new entry here; no match on the id needs to grow.
pub struct ProviderDescriptor {
    id: ProviderId,
    display_name: &'static str,
    fetch: fn() -> FetchFuture,
}

impl ProviderDescriptor {
    const fn new(id: ProviderId, display_name: &'static str, fetch: fn() -> FetchFuture) -> Self {
        Self {
            id,
            display_name,
            fetch,
        }
    }

    pub fn id(&self) -> &ProviderId {
        &self.id
    }

    pub fn display_name(&self) -> &'static str {
        self.display_name
    }
}

/// The providers this build can fetch, in the order shells show them.
pub static PROVIDERS: &[ProviderDescriptor] = &[
    ProviderDescriptor::new(ProviderId::Cursor, "Cursor", || {
        Box::pin(CursorProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::ClaudeCode, "Claude Code", || {
        Box::pin(ClaudeCodeProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::ClaudeDesktop, "Claude Desktop", || {
        Box::pin(ClaudeDesktopProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::Copilot, "GitHub Copilot", || {
        Box::pin(CopilotProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::GrokBot, "Grok Bot", || {
        Box::pin(GrokBotProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::Codex, "Codex", || {
        Box::pin(CodexProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::OpenCode, "OpenCode", || {
        Box::pin(OpenCodeProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::Kimi, "Kimi", || Box::pin(KimiProvider.fetch())),
    ProviderDescriptor::new(ProviderId::Grok, "Grok", || Box::pin(GrokProvider.fetch())),
    ProviderDescriptor::new(ProviderId::Apify, "Apify", || {
        Box::pin(ApifyProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::Devin, "Devin", || {
        Box::pin(DevinProvider.fetch())
    }),
    ProviderDescriptor::new(ProviderId::Amp, "Amp", || Box::pin(AmpProvider.fetch())),
    ProviderDescriptor::new(ProviderId::Kiro, "Kiro", || Box::pin(KiroProvider.fetch())),
    ProviderDescriptor::new(ProviderId::Kilo, "Kilo", || Box::pin(KiloProvider.fetch())),
    ProviderDescriptor::new(ProviderId::Glm, "GLM", || Box::pin(GlmProvider.fetch())),
    ProviderDescriptor::new(ProviderId::CommandCode, "Command Code", || {
        Box::pin(CommandCodeProvider.fetch())
    }),
];

pub fn descriptor(id: &ProviderId) -> Option<&'static ProviderDescriptor> {
    PROVIDERS.iter().find(|provider| provider.id == *id)
}

pub async fn fetch_provider(id: ProviderId, config: &AppConfig) -> UsageReading {
    if !config.provider_enabled(&id) {
        return UsageReading::disabled(id);
    }
    let Some(provider) = descriptor(&id) else {
        return UsageReading::disabled(id);
    };

    let result = (provider.fetch)().await;

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
            descriptor(&ProviderId::OpenCode).map(ProviderDescriptor::display_name),
            Some("OpenCode")
        );
        assert_eq!(
            descriptor(&ProviderId::new("claude_code")).map(ProviderDescriptor::display_name),
            Some("Claude Code")
        );
        assert!(descriptor(&ProviderId::new("future_tool")).is_none());
    }
}
