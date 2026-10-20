//! Usage limit alerts: one when a provider's tightest window passes 80%, one
//! when it reaches 100%.
//!
//! Each provider keeps the highest threshold already announced. It comes back
//! down, and so can be announced again, only once usage falls 10 points below
//! it: a window that resets, or a rolling one that frees up. Usage hovering
//! around a threshold announces it once. The first reading of a run sets the
//! starting point without an alert, so restarting the engine at 85% says
//! nothing new.

use std::collections::HashMap;

use crate::protocol::{LimitAlert, ProviderId, ReadingStatus, UsageReading};

/// The thresholds, lowest first.
pub const THRESHOLDS: [u8; 2] = [80, 100];

/// How far below an announced threshold usage must fall before it can be
/// announced again.
const REARM_POINTS: f64 = 10.0;

#[derive(Default)]
pub struct LimitWatch {
    announced: HashMap<ProviderId, u8>,
}

impl LimitWatch {
    /// Follows one reading; returns the alert it crosses into, if any.
    /// Readings without fresh numbers (stale, failed, signed out) are
    /// skipped and leave the state as it was.
    pub fn check(&mut self, reading: &UsageReading) -> Option<LimitAlert> {
        if reading.status != ReadingStatus::Ok {
            return None;
        }
        let window = reading.tightest_window()?;
        let pct = window.used_pct;
        let reached = level(pct);

        let Some(announced) = self.announced.get_mut(&reading.provider) else {
            self.announced.insert(reading.provider.clone(), reached);
            return None;
        };
        while *announced > 0 && pct < f64::from(*announced) - REARM_POINTS {
            *announced = below(*announced);
        }
        if reached <= *announced {
            return None;
        }
        *announced = reached;
        Some(LimitAlert {
            provider: reading.provider.clone(),
            display_name: reading.display_name.clone(),
            label: window.label.clone(),
            used_pct: pct,
            threshold: reached,
            resets_at: window.resets_at,
        })
    }
}

/// The highest threshold `pct` has reached, or 0.
fn level(pct: f64) -> u8 {
    THRESHOLDS
        .iter()
        .rev()
        .copied()
        .find(|t| pct >= f64::from(*t))
        .unwrap_or(0)
}

/// The threshold under `threshold`, or 0.
fn below(threshold: u8) -> u8 {
    THRESHOLDS
        .iter()
        .rev()
        .copied()
        .find(|t| *t < threshold)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Fidelity, UsageWindow};
    use chrono::Utc;

    fn reading(pct: f64) -> UsageReading {
        reading_as(ProviderId::ClaudeCode, pct, ReadingStatus::Ok)
    }

    fn reading_as(provider: ProviderId, pct: f64, status: ReadingStatus) -> UsageReading {
        UsageReading {
            provider,
            display_name: "Claude Code".into(),
            fidelity: Fidelity::Official,
            status,
            windows: vec![UsageWindow {
                label: "Current session".into(),
                used_pct: pct,
                resets_at: None,
            }],
            fetched_at: Utc::now(),
            message: None,
        }
    }

    fn thresholds(watch: &mut LimitWatch, pcts: &[f64]) -> Vec<u8> {
        pcts.iter()
            .filter_map(|pct| watch.check(&reading(*pct)))
            .map(|alert| alert.threshold)
            .collect()
    }

    #[test]
    fn announces_each_threshold_once_as_usage_climbs() {
        let mut watch = LimitWatch::default();
        assert_eq!(
            thresholds(&mut watch, &[40.0, 79.9, 80.0, 85.0, 99.0, 100.0, 100.0]),
            vec![80, 100]
        );
    }

    #[test]
    fn a_jump_past_both_announces_only_the_top_one() {
        let mut watch = LimitWatch::default();
        assert_eq!(thresholds(&mut watch, &[50.0, 100.0, 90.0]), vec![100]);
    }

    #[test]
    fn starting_above_a_threshold_says_nothing() {
        let mut watch = LimitWatch::default();
        assert_eq!(thresholds(&mut watch, &[85.0, 88.0, 100.0]), vec![100]);
    }

    #[test]
    fn hovering_around_a_threshold_announces_it_once() {
        let mut watch = LimitWatch::default();
        assert_eq!(
            thresholds(&mut watch, &[70.0, 80.5, 79.5, 80.2, 75.0, 81.0]),
            vec![80]
        );
    }

    #[test]
    fn a_new_window_announces_again() {
        let mut watch = LimitWatch::default();
        assert_eq!(
            thresholds(&mut watch, &[60.0, 100.0, 3.0, 82.0, 100.0]),
            vec![100, 80, 100]
        );
        // Freed up only to 85%: 100% can come again, 80% cannot.
        let mut rolling = LimitWatch::default();
        assert_eq!(
            thresholds(&mut rolling, &[60.0, 100.0, 85.0, 100.0]),
            vec![100, 100]
        );
    }

    #[test]
    fn stale_readings_and_other_providers_are_their_own() {
        let mut watch = LimitWatch::default();
        watch.check(&reading(50.0));
        let stale = reading_as(ProviderId::ClaudeCode, 95.0, ReadingStatus::Stale);
        assert!(watch.check(&stale).is_none());
        assert!(watch
            .check(&reading_as(ProviderId::Codex, 90.0, ReadingStatus::Ok))
            .is_none());
        let alert = watch.check(&reading(95.0)).unwrap();
        assert_eq!(alert.threshold, 80);
        assert_eq!(alert.label, "Current session");
        assert_eq!(alert.used_pct, 95.0);
    }

    #[test]
    fn tightest_window_drives_the_alert() {
        let mut watch = LimitWatch::default();
        let low = UsageReading {
            provider: ProviderId::ClaudeCode,
            display_name: "Claude Code".into(),
            fidelity: Fidelity::Official,
            status: ReadingStatus::Ok,
            windows: vec![
                UsageWindow {
                    label: "Current session".into(),
                    used_pct: 0.0,
                    resets_at: None,
                },
                UsageWindow {
                    label: "Weekly limit".into(),
                    used_pct: 50.0,
                    resets_at: None,
                },
            ],
            fetched_at: Utc::now(),
            message: None,
        };
        assert!(watch.check(&low).is_none());

        let high = UsageReading {
            windows: vec![
                UsageWindow {
                    label: "Current session".into(),
                    used_pct: 0.0,
                    resets_at: None,
                },
                UsageWindow {
                    label: "Weekly limit".into(),
                    used_pct: 97.0,
                    resets_at: None,
                },
            ],
            ..low.clone()
        };
        let alert = watch.check(&high).unwrap();
        assert_eq!(alert.threshold, 80);
        assert_eq!(alert.label, "Weekly limit");
        assert_eq!(alert.used_pct, 97.0);
    }
}
