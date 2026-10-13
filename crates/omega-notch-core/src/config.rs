use serde::{Deserialize, Serialize};

use crate::protocol::ProviderId;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub edge: Edge,
    /// Position along the edge, 0.0..=1.0 (0 = start, 1 = end).
    pub edge_position: f64,
    pub size: SizePreset,
    pub accent: Accent,
    pub providers: ProviderToggles,
    pub alerts: AlertSettings,
    pub peek_seconds: u32,
    /// Tuck the notch away until a session ends or the pointer comes for it.
    #[serde(default = "default_auto_hide")]
    pub auto_hide: bool,
    /// Rings shown at once, busiest providers first.
    #[serde(default = "default_max_providers")]
    pub max_providers: u32,
    /// Scale of the nub left on the edge while the notch is tucked away.
    #[serde(default = "default_idle_size")]
    pub idle_size: f64,
    /// Colour of that nub, as `#RRGGBB`.
    #[serde(default = "default_idle_color")]
    pub idle_color: String,
    /// How the nub moves while a session works, by name (see
    /// `NUB_MOTIONS`); an unknown name falls back to the default.
    #[serde(default = "default_nub_working")]
    pub nub_working: String,
    /// The same, while a session waits for you.
    #[serde(default = "default_nub_waiting")]
    pub nub_waiting: String,
    /// Colour of the notch itself, as `#RRGGBB`, independent of the nub.
    #[serde(default)]
    pub notch_color: String,
    /// Older configs painted the notch in `idle_color` when this was on; only
    /// read to fill in `notch_color`.
    #[serde(default, skip_serializing)]
    pub color_notch: Option<bool>,
    /// Output the notch lives on, by connector name (`DP-1`); empty follows
    /// the primary screen.
    #[serde(default)]
    pub screen: String,
}

pub const MAX_PROVIDERS_LIMIT: u32 = 5;
pub const IDLE_SIZE_MAX: f64 = 3.0;
/// The motions a nub can play; `none` keeps it still.
pub const NUB_MOTIONS: [&str; 7] = [
    "none", "shiver", "breathe", "wave", "pulse", "bounce", "stretch",
];

fn default_idle_size() -> f64 {
    1.0
}

fn default_idle_color() -> String {
    "#000000".to_string()
}

fn default_nub_working() -> String {
    "shiver".to_string()
}

fn default_nub_waiting() -> String {
    "pulse".to_string()
}

fn default_notch_color() -> String {
    "#000000".to_string()
}

fn is_hex_color(value: &str) -> bool {
    value.len() == 7 && value.starts_with('#') && value[1..].chars().all(|c| c.is_ascii_hexdigit())
}

fn default_true() -> bool {
    true
}

fn default_auto_hide() -> bool {
    true
}

fn default_max_providers() -> u32 {
    1
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SizePreset {
    Small,
    Medium,
    Large,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Accent {
    Plasma,
    Fixed { hex: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderToggles {
    pub cursor: bool,
    pub claude_code: bool,
    pub claude_desktop: bool,
    #[serde(default = "default_true")]
    pub copilot: bool,
    #[serde(default = "default_true")]
    pub grok_bot: bool,
    #[serde(default = "default_true")]
    pub codex: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlertSettings {
    pub enabled: bool,
    pub sound: bool,
    /// The sound for a session that finished, by name: a macOS system
    /// sound such as `Glass`, or a freedesktop sound such as
    /// `completion-success` on Plasma. Empty, or a name the shell does not
    /// offer, picks the shell's default.
    #[serde(default)]
    pub sound_finished: String,
    /// The same, for a session that stopped to ask you something.
    #[serde(default)]
    pub sound_waiting: String,
    /// Whether to announce a provider's usage passing 80% and reaching 100%.
    #[serde(default = "default_true")]
    pub limits: bool,
    pub mute_cursor: bool,
    pub mute_claude_code: bool,
    pub mute_claude_desktop: bool,
    #[serde(default)]
    pub mute_copilot: bool,
    #[serde(default)]
    pub mute_grok_bot: bool,
    #[serde(default)]
    pub mute_codex: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            // On a Mac the notch grows out of the camera housing.
            edge: if cfg!(target_os = "macos") {
                Edge::Top
            } else {
                Edge::Right
            },
            edge_position: 0.5,
            size: SizePreset::Medium,
            accent: Accent::Plasma,
            providers: ProviderToggles {
                cursor: true,
                claude_code: true,
                claude_desktop: true,
                copilot: true,
                grok_bot: true,
                codex: true,
            },
            alerts: AlertSettings {
                enabled: true,
                sound: true,
                sound_finished: String::new(),
                sound_waiting: String::new(),
                limits: true,
                mute_cursor: false,
                mute_claude_code: false,
                mute_claude_desktop: false,
                mute_copilot: false,
                mute_grok_bot: false,
                mute_codex: false,
            },
            peek_seconds: 5,
            auto_hide: default_auto_hide(),
            max_providers: default_max_providers(),
            idle_size: default_idle_size(),
            idle_color: default_idle_color(),
            nub_working: default_nub_working(),
            nub_waiting: default_nub_waiting(),
            notch_color: default_notch_color(),
            color_notch: None,
            screen: String::new(),
        }
    }
}

impl AppConfig {
    pub fn provider_enabled(&self, id: ProviderId) -> bool {
        match id {
            ProviderId::Cursor => self.providers.cursor,
            ProviderId::ClaudeCode => self.providers.claude_code,
            ProviderId::ClaudeDesktop => self.providers.claude_desktop,
            ProviderId::Copilot => self.providers.copilot,
            ProviderId::GrokBot => self.providers.grok_bot,
            ProviderId::Codex => self.providers.codex,
            _ => false,
        }
    }

    pub fn alerts_muted(&self, id: ProviderId) -> bool {
        if !self.alerts.enabled {
            return true;
        }
        match id {
            ProviderId::Cursor => self.alerts.mute_cursor,
            ProviderId::ClaudeCode => self.alerts.mute_claude_code,
            ProviderId::ClaudeDesktop => self.alerts.mute_claude_desktop,
            ProviderId::Copilot => self.alerts.mute_copilot,
            ProviderId::GrokBot => self.alerts.mute_grok_bot,
            ProviderId::Codex => self.alerts.mute_codex,
            _ => true,
        }
    }

    pub fn load() -> Self {
        let path = crate::paths::config_file();
        match std::fs::read_to_string(&path) {
            Ok(raw) => serde_json::from_str::<Self>(&raw)
                .map(Self::normalized)
                .unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn normalized(mut self) -> Self {
        self.max_providers = self.max_providers.clamp(1, MAX_PROVIDERS_LIMIT);
        self.idle_size = if self.idle_size.is_finite() {
            self.idle_size.clamp(1.0, IDLE_SIZE_MAX)
        } else {
            default_idle_size()
        };
        if !is_hex_color(&self.idle_color) {
            self.idle_color = default_idle_color();
        }
        if !NUB_MOTIONS.contains(&self.nub_working.as_str()) {
            self.nub_working = default_nub_working();
        }
        if !NUB_MOTIONS.contains(&self.nub_waiting.as_str()) {
            self.nub_waiting = default_nub_waiting();
        }
        if !is_hex_color(&self.notch_color) {
            self.notch_color = if self.color_notch.unwrap_or(true) {
                self.idle_color.clone()
            } else {
                default_notch_color()
            };
        }
        self.color_notch = None;
        self.screen = self.screen.trim().to_string();
        self
    }

    pub fn save(&self) -> anyhow::Result<()> {
        let path = crate::paths::config_file();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let raw = serde_json::to_string_pretty(self)?;
        std::fs::write(path, raw)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(extra: &str) -> AppConfig {
        let mut value = serde_json::to_value(AppConfig::default()).unwrap();
        let map = value.as_object_mut().unwrap();
        map.remove("notch_color");
        map.remove("screen");
        let extra: serde_json::Value = serde_json::from_str(extra).unwrap();
        for (k, v) in extra.as_object().unwrap() {
            map.insert(k.clone(), v.clone());
        }
        serde_json::from_value::<AppConfig>(value)
            .unwrap()
            .normalized()
    }

    #[test]
    fn old_color_notch_on_paints_notch_in_idle_color() {
        let c = parse(r##"{"idle_color":"#FF5A36","color_notch":true}"##);
        assert_eq!(c.notch_color, "#FF5A36");
        assert_eq!(c.screen, "");
    }

    #[test]
    fn old_color_notch_off_keeps_notch_black() {
        let c = parse(r##"{"idle_color":"#FF5A36","color_notch":false}"##);
        assert_eq!(c.notch_color, "#000000");
        assert!(!serde_json::to_string(&c).unwrap().contains("color_notch"));
    }

    #[test]
    fn notch_color_is_independent_of_idle_color() {
        let c = parse(r##"{"idle_color":"#000000","notch_color":"#4C8DFF","screen":" DP-1 "}"##);
        assert_eq!(c.idle_color, "#000000");
        assert_eq!(c.notch_color, "#4C8DFF");
        assert_eq!(c.screen, "DP-1");
    }

    #[test]
    fn nub_motions_default_and_reject_unknown_names() {
        let mut value = serde_json::to_value(AppConfig::default()).unwrap();
        let map = value.as_object_mut().unwrap();
        map.remove("nub_working");
        map.insert("nub_waiting".into(), "wiggle".into());
        let c = serde_json::from_value::<AppConfig>(value)
            .unwrap()
            .normalized();
        assert_eq!(c.nub_working, "shiver");
        assert_eq!(c.nub_waiting, "pulse");

        let c = parse(r#"{"nub_working":"wave","nub_waiting":"none"}"#);
        assert_eq!(c.nub_working, "wave");
        assert_eq!(c.nub_waiting, "none");
    }
}
