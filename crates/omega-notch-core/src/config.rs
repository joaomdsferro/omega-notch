use std::collections::BTreeMap;

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
    /// The dashboard's series colours, by name (see `DASHBOARD_PALETTES`);
    /// an unknown name falls back to the default.
    #[serde(default = "default_dashboard_palette")]
    pub dashboard_palette: String,
    /// Colours over the palette's, first series first, as `#RRGGBB`; an empty
    /// one keeps the palette's. At most `DASHBOARD_SERIES`.
    #[serde(default)]
    pub dashboard_colors: Vec<String>,
    /// The theme the shells paint with, by name (see `THEMES`); an unknown
    /// name falls back to the default.
    #[serde(default = "default_theme")]
    pub theme: String,
    /// Providers the user starred; the notch prefers them over idle ones.
    #[serde(default)]
    pub favorites: Vec<String>,
    /// The order the notch lays its rings out in, first to last. Providers
    /// it does not name follow, in the registry's order.
    #[serde(default)]
    pub notch_order: Vec<String>,
    /// Providers off only because nothing of them was on this machine when
    /// the config first named them. One turns on by itself once it shows up;
    /// switching it on by hand takes it off this list.
    #[serde(default)]
    pub undetected: Vec<String>,
}

/// Most ids a provider list may hold, and the longest id in one: the config
/// comes from a socket, so what it holds is bounded.
pub const PROVIDER_LIST_MAX: usize = 64;
const PROVIDER_ID_MAX: usize = 48;

pub const MAX_PROVIDERS_LIMIT: u32 = 5;
pub const IDLE_SIZE_MAX: f64 = 3.0;
/// The motions a nub can play; `none` keeps it still.
pub const NUB_MOTIONS: [&str; 7] = [
    "none", "shiver", "breathe", "wave", "pulse", "bounce", "stretch",
];

/// The dashboard palettes; the shells hold their colours.
pub const DASHBOARD_PALETTES: [&str; 3] = ["mono", "vivid", "colorblind"];
/// Series the dashboard tells apart by colour; later ones reuse the last.
pub const DASHBOARD_SERIES: usize = 6;

/// The themes the shells can paint with. The first is the default; the rest
/// are chosen in Settings, under Appearance.
pub const THEMES: [&str; 6] = ["noir", "classic", "vidro", "clube", "aurora", "terminal"];

fn default_theme() -> String {
    "noir".to_string()
}

fn default_dashboard_palette() -> String {
    "mono".to_string()
}

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

/// Keeps ids that look like a provider id, once each, in order, up to
/// `PROVIDER_LIST_MAX`.
fn clean_provider_list(list: &mut Vec<String>) {
    let mut seen = std::collections::HashSet::new();
    list.retain(|id| {
        !id.is_empty()
            && id.len() <= PROVIDER_ID_MAX
            && id
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
            && seen.insert(id.clone())
    });
    list.truncate(PROVIDER_LIST_MAX);
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

/// Which providers are on. Kept as an open map so a provider added by a
/// newer engine is not lost when an older shell writes the config back.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProviderToggles(BTreeMap<String, bool>);

impl ProviderToggles {
    /// Every provider this build knows, on. Explicit in the config so an
    /// older shell sees the whole list. A config read from disk is settled
    /// from what is installed instead (`AppConfig::settle_providers`).
    pub fn defaults() -> Self {
        let mut toggles = Self::default();
        for provider in crate::providers::PROVIDERS {
            toggles.0.insert(provider.id().as_str().to_string(), true);
        }
        toggles
    }

    /// A provider without an entry is on: new providers work without a
    /// migration, and configs from before the setting stay enabled.
    pub fn enabled(&self, id: &ProviderId) -> bool {
        self.0.get(id.as_str()).copied().unwrap_or(true)
    }

    pub fn set(&mut self, id: &ProviderId, enabled: bool) {
        self.0.insert(id.as_str().to_string(), enabled);
    }

    pub fn names(&self, id: &ProviderId) -> bool {
        self.0.contains_key(id.as_str())
    }
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
    /// Whether each alert is also a system notification. Off by default:
    /// the notch and the sound are the alert.
    #[serde(default)]
    pub system_notifications: bool,
    /// Whether the notch opens for a few seconds with each alert.
    #[serde(default = "default_true")]
    pub open_notch: bool,
    /// Decide that per alert instead, with the three below.
    #[serde(default)]
    pub open_notch_split: bool,
    #[serde(default = "default_true")]
    pub open_notch_finished: bool,
    #[serde(default = "default_true")]
    pub open_notch_waiting: bool,
    #[serde(default = "default_true")]
    pub open_notch_limits: bool,
    /// Whether to announce a provider's usage passing 80% and reaching 100%.
    #[serde(default = "default_true")]
    pub limits: bool,
    /// Providers whose limit alerts are muted. Absent means not muted.
    #[serde(default)]
    pub muted: BTreeMap<String, bool>,
    /// The pre-map switches, read once and folded into `muted`. Only read:
    /// shells now use `muted`, and a config without these stays valid.
    #[serde(default, skip_serializing)]
    pub mute_cursor: bool,
    #[serde(default, skip_serializing)]
    pub mute_claude_code: bool,
    #[serde(default, skip_serializing)]
    pub mute_claude_desktop: bool,
    #[serde(default, skip_serializing)]
    pub mute_copilot: bool,
    #[serde(default, skip_serializing)]
    pub mute_grok_bot: bool,
    #[serde(default, skip_serializing)]
    pub mute_codex: bool,
    #[serde(default, skip_serializing)]
    pub mute_opencode: bool,
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
            providers: ProviderToggles::defaults(),
            alerts: AlertSettings {
                enabled: true,
                sound: true,
                sound_finished: String::new(),
                sound_waiting: String::new(),
                system_notifications: false,
                open_notch: true,
                open_notch_split: false,
                open_notch_finished: true,
                open_notch_waiting: true,
                open_notch_limits: true,
                limits: true,
                muted: BTreeMap::new(),
                mute_cursor: false,
                mute_claude_code: false,
                mute_claude_desktop: false,
                mute_copilot: false,
                mute_grok_bot: false,
                mute_codex: false,
                mute_opencode: false,
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
            dashboard_palette: default_dashboard_palette(),
            dashboard_colors: Vec::new(),
            theme: default_theme(),
            favorites: Vec::new(),
            notch_order: Vec::new(),
            undetected: Vec::new(),
        }
    }
}

impl AppConfig {
    pub fn provider_enabled(&self, id: &ProviderId) -> bool {
        self.providers.enabled(id)
    }

    pub fn alerts_muted(&self, id: &ProviderId) -> bool {
        !self.alerts.enabled || self.alerts.muted.get(id.as_str()).copied().unwrap_or(false)
    }

    pub fn load() -> Self {
        Self::read().0
    }

    /// `load`, writing the config back when providers it did not name were
    /// settled from this machine: on a new machine, the first run decides
    /// once which providers start on.
    pub fn load_settled() -> Self {
        let (config, settled) = Self::read();
        if settled {
            if let Err(err) = config.save() {
                tracing::warn!(error = %err, "could not save the detected providers");
            }
        }
        config
    }

    fn read() -> (Self, bool) {
        let path = crate::paths::config_file();
        let mut config = std::fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<Self>(&raw).ok())
            .map(Self::normalized)
            .unwrap_or_else(|| Self {
                providers: ProviderToggles::default(),
                ..Self::default()
            });
        let settled = config.settle_providers(crate::providers::detected);
        (config, settled)
    }

    /// Names every provider of this build the config does not name yet: on
    /// when `found` sees it on this machine, off and listed in `undetected`
    /// otherwise. Returns whether it named any.
    pub fn settle_providers(&mut self, found: impl Fn(&ProviderId) -> bool) -> bool {
        let mut settled = false;
        for provider in crate::providers::PROVIDERS {
            let id = provider.id();
            if self.providers.names(id) {
                continue;
            }
            let on = found(id);
            self.providers.set(id, on);
            if !on {
                self.undetected.push(id.as_str().to_string());
            }
            settled = true;
        }
        settled
    }

    /// Switches on the `undetected` providers that `found` now sees.
    /// Returns whether any was.
    pub fn adopt_found_providers(&mut self, found: impl Fn(&ProviderId) -> bool) -> bool {
        let before = self.undetected.len();
        let toggles = &mut self.providers;
        self.undetected.retain(|id| {
            let id = ProviderId::new(id.clone());
            if !found(&id) {
                return true;
            }
            toggles.set(&id, true);
            false
        });
        self.undetected.len() != before
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
        if !DASHBOARD_PALETTES.contains(&self.dashboard_palette.as_str()) {
            self.dashboard_palette = default_dashboard_palette();
        }
        if !THEMES.contains(&self.theme.as_str()) {
            self.theme = default_theme();
        }
        for (id, muted) in [
            ("cursor", self.alerts.mute_cursor),
            ("claude_code", self.alerts.mute_claude_code),
            ("claude_desktop", self.alerts.mute_claude_desktop),
            ("copilot", self.alerts.mute_copilot),
            ("grok_bot", self.alerts.mute_grok_bot),
            ("codex", self.alerts.mute_codex),
            ("opencode", self.alerts.mute_opencode),
        ] {
            if muted {
                self.alerts.muted.insert(id.to_string(), true);
            }
        }
        clean_provider_list(&mut self.favorites);
        clean_provider_list(&mut self.notch_order);
        clean_provider_list(&mut self.undetected);
        let toggles = &self.providers;
        self.undetected
            .retain(|id| !toggles.enabled(&ProviderId::new(id.clone())));
        self.dashboard_colors.truncate(DASHBOARD_SERIES);
        for color in &mut self.dashboard_colors {
            *color = if is_hex_color(color) {
                color.to_ascii_uppercase()
            } else {
                String::new()
            };
        }
        while self.dashboard_colors.last().is_some_and(String::is_empty) {
            self.dashboard_colors.pop();
        }
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
        map.remove("dashboard_palette");
        map.remove("dashboard_colors");
        map.remove("theme");
        let extra: serde_json::Value = serde_json::from_str(extra).unwrap();
        for (k, v) in extra.as_object().unwrap() {
            map.insert(k.clone(), v.clone());
        }
        serde_json::from_value::<AppConfig>(value)
            .unwrap()
            .normalized()
    }

    #[test]
    fn alerts_open_the_notch_unless_told_not_to() {
        let mut value = serde_json::to_value(AppConfig::default()).unwrap();
        let alerts = value["alerts"].as_object_mut().unwrap();
        for key in [
            "open_notch",
            "open_notch_split",
            "open_notch_finished",
            "open_notch_waiting",
            "open_notch_limits",
            "system_notifications",
        ] {
            alerts.remove(key);
        }
        let old: AppConfig = serde_json::from_value(value).unwrap();
        assert!(old.alerts.open_notch);
        assert!(!old.alerts.open_notch_split);
        assert!(old.alerts.open_notch_finished && old.alerts.open_notch_waiting);
        assert!(old.alerts.open_notch_limits);
        // An old config gets no system notifications either: the notch is the
        // alert now.
        assert!(!old.alerts.system_notifications);
        let off = parse(
            r#"{"alerts":{"enabled":true,"sound":true,"open_notch":false,
            "mute_cursor":false,"mute_claude_code":false,"mute_claude_desktop":false}}"#,
        );
        assert!(!off.alerts.open_notch);
    }

    #[test]
    fn provider_toggles_keep_unknown_ids_and_default_to_on() {
        let c = parse(r#"{"providers":{"cursor":false,"future_tool":false}}"#);
        assert!(!c.provider_enabled(&ProviderId::Cursor));
        // A provider the config does not name is on.
        assert!(c.provider_enabled(&ProviderId::ClaudeCode));
        assert!(!c.provider_enabled(&ProviderId::new("future_tool")));
        let raw = serde_json::to_string(&c).unwrap();
        assert!(raw.contains(r#""future_tool":false"#));
    }

    #[test]
    fn a_new_machine_starts_with_only_the_providers_found_on_it() {
        let mut c = AppConfig {
            providers: ProviderToggles::default(),
            ..AppConfig::default()
        };
        let found = |id: &ProviderId| *id == ProviderId::Codex || *id == ProviderId::Cursor;
        assert!(c.settle_providers(found));
        assert!(c.provider_enabled(&ProviderId::Codex));
        assert!(c.provider_enabled(&ProviderId::Cursor));
        assert!(!c.provider_enabled(&ProviderId::ClaudeCode));
        assert!(c.undetected.contains(&"claude_code".to_string()));
        assert!(!c.undetected.contains(&"codex".to_string()));
        assert_eq!(c.undetected.len(), crate::providers::PROVIDERS.len() - 2);

        // Settled once: a second run leaves the choice alone.
        assert!(!c.settle_providers(|_| true));
        assert!(!c.provider_enabled(&ProviderId::ClaudeCode));
    }

    #[test]
    fn a_config_that_names_a_provider_keeps_its_choice() {
        let mut c = parse(r#"{"providers":{"cursor":true,"codex":false}}"#);
        c.settle_providers(|_| false);
        assert!(c.provider_enabled(&ProviderId::Cursor));
        assert!(!c.provider_enabled(&ProviderId::Codex));
        assert!(!c.undetected.contains(&"codex".to_string()));
        assert!(!c.undetected.contains(&"cursor".to_string()));
        // One the file did not name follows the machine.
        assert!(!c.provider_enabled(&ProviderId::Kimi));
        assert!(c.undetected.contains(&"kimi".to_string()));
    }

    #[test]
    fn an_undetected_provider_turns_on_once_it_shows_up() {
        let mut c = AppConfig {
            providers: ProviderToggles::default(),
            ..AppConfig::default()
        };
        c.settle_providers(|_| false);
        assert!(!c.adopt_found_providers(|_| false));
        assert!(c.adopt_found_providers(|id| *id == ProviderId::Kiro));
        assert!(c.provider_enabled(&ProviderId::Kiro));
        assert!(!c.undetected.contains(&"kiro".to_string()));
        assert!(!c.provider_enabled(&ProviderId::Amp));
    }

    #[test]
    fn switching_an_undetected_provider_on_by_hand_makes_it_the_users() {
        let mut c = AppConfig {
            providers: ProviderToggles::default(),
            ..AppConfig::default()
        };
        c.settle_providers(|_| false);
        c.providers.set(&ProviderId::Amp, true);
        let mut c = c.normalized();
        assert!(!c.undetected.contains(&"amp".to_string()));
        // Off again by hand: it stays off even once found.
        c.providers.set(&ProviderId::Amp, false);
        c.adopt_found_providers(|_| true);
        assert!(!c.provider_enabled(&ProviderId::Amp));
    }

    #[test]
    fn old_mutes_migrate_to_the_muted_map() {
        let c = parse(
            r#"{"alerts":{"enabled":true,"sound":true,"mute_cursor":true,
            "mute_claude_code":false}}"#,
        );
        assert!(c.alerts_muted(&ProviderId::Cursor));
        assert!(!c.alerts_muted(&ProviderId::Codex));
        let raw = serde_json::to_string(&c).unwrap();
        assert!(!raw.contains("mute_cursor"));
        assert!(raw.contains(r#""muted":{"cursor":true}"#));
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

    #[test]
    fn dashboard_colours_keep_known_palettes_and_valid_overrides() {
        let c =
            parse(r##"{"dashboard_palette":"vivid","dashboard_colors":["#4c8dff","red","",""]}"##);
        assert_eq!(c.dashboard_palette, "vivid");
        assert_eq!(c.dashboard_colors, vec!["#4C8DFF".to_string()]);

        let c = parse(
            r##"{"dashboard_palette":"rainbow","dashboard_colors":["#000001","#000002","#000003","#000004","#000005","#000006","#000007"]}"##,
        );
        assert_eq!(c.dashboard_palette, "mono");
        assert_eq!(c.dashboard_colors.len(), DASHBOARD_SERIES);

        // Older configs have neither.
        let c = parse("{}");
        assert_eq!(c.dashboard_palette, "mono");
        assert!(c.dashboard_colors.is_empty());
    }

    #[test]
    fn favorites_and_notch_order_are_cleaned_and_bounded() {
        let c = parse(
            r#"{"favorites":["codex","codex","Bad Id","","claude_code-work"],
            "notch_order":["cursor","../x","cursor","codex"]}"#,
        );
        assert_eq!(c.favorites, vec!["codex", "claude_code-work"]);
        assert_eq!(c.notch_order, vec!["cursor", "codex"]);

        let many: Vec<String> = (0..200).map(|n| format!("p{n}")).collect();
        let c = parse(&format!(r#"{{"favorites":{}}}"#, serde_json::to_string(&many).unwrap()));
        assert_eq!(c.favorites.len(), PROVIDER_LIST_MAX);

        // Older configs have neither.
        let c = parse("{}");
        assert!(c.favorites.is_empty() && c.notch_order.is_empty());
    }

    #[test]
    fn themes_keep_known_names_and_fall_back_to_the_default() {
        let c = parse(r#"{"theme":"clube"}"#);
        assert_eq!(c.theme, "clube");

        let c = parse(r#"{"theme":"neon"}"#);
        assert_eq!(c.theme, "noir");

        // A config from before the setting has none at all.
        let c = parse("{}");
        assert_eq!(c.theme, "noir");
        assert!(THEMES.contains(&c.theme.as_str()));
    }
}
