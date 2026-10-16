//! Shared types, providers, poller, and session watchers for Omega Notch.

pub mod advice;
pub mod analysis;
pub mod chats;
pub mod config;
pub mod copilot_auth;
pub mod doctor;
pub mod history;
pub mod jump;
pub mod limits;
pub mod paths;
pub mod platform;
pub mod pricing;
pub mod protocol;
pub mod providers;
pub mod seen;
pub mod sessions;
pub mod store;

/// Sent with every HTTP request to a provider.
pub const USER_AGENT: &str = concat!("omega-notch/", env!("CARGO_PKG_VERSION"));

pub use config::AppConfig;
pub use protocol::*;
pub use store::UsageStore;
