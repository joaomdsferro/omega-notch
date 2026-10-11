use thiserror::Error;

use crate::protocol::ProviderId;

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("{0}")]
    NeedsAuth(String),
    #[error("{0}")]
    Message(String),
    #[error("provider not supported: {0:?}")]
    Unsupported(ProviderId),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl From<String> for ProviderError {
    fn from(value: String) -> Self {
        Self::Message(value)
    }
}

impl From<&str> for ProviderError {
    fn from(value: &str) -> Self {
        Self::Message(value.to_string())
    }
}

/// Marker trait documentation only — concrete providers expose `fetch`.
pub trait Provider {
    fn id(&self) -> ProviderId;
}
