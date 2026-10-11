mod claude_code;
mod claude_desktop;
mod codex;
mod copilot;
mod cursor;
mod grok_bot;
mod traits;

pub use claude_code::ClaudeCodeProvider;
pub use claude_desktop::ClaudeDesktopProvider;
pub use codex::CodexProvider;
pub use copilot::CopilotProvider;
pub use cursor::CursorProvider;
pub use grok_bot::GrokBotProvider;
pub use traits::{Provider, ProviderError};

use crate::config::AppConfig;
use crate::protocol::{ProviderId, UsageReading};

pub async fn fetch_provider(id: ProviderId, config: &AppConfig) -> UsageReading {
    if !config.provider_enabled(id) {
        return UsageReading::disabled(id);
    }

    let result = match id {
        ProviderId::Cursor => CursorProvider.fetch().await,
        ProviderId::ClaudeCode => ClaudeCodeProvider.fetch().await,
        ProviderId::ClaudeDesktop => ClaudeDesktopProvider.fetch().await,
        ProviderId::Copilot => CopilotProvider.fetch().await,
        ProviderId::GrokBot => GrokBotProvider.fetch().await,
        ProviderId::Codex => CodexProvider.fetch().await,
        other => Err(ProviderError::Unsupported(other)),
    };

    match result {
        Ok(reading) => reading,
        Err(ProviderError::NeedsAuth(msg)) => UsageReading::needs_auth(id, msg),
        Err(ProviderError::Unsupported(_)) => UsageReading::disabled(id),
        Err(err) => UsageReading::error(id, err.to_string()),
    }
}
