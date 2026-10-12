//! Rough cost estimates for the dashboard.
//!
//! Nothing here is billed: vendors price per model and change prices without
//! notice, and subscription plans are not metered per token at all, so every
//! number is labelled "estimated" in the UI. Claude prices are Anthropic's
//! first-party list prices per model; cache writes are taken at 1.25x input
//! (the five-minute cache). Other vendors are approximated.

use crate::protocol::TokenTotals;

/// USD per 1M tokens.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Price {
    input: f64,
    output: f64,
    cache_read: f64,
}

impl Price {
    /// Cache reads at a tenth of input, the usual Anthropic ratio.
    const fn standard(input: f64, output: f64) -> Self {
        Self {
            input,
            output,
            cache_read: input * 0.1,
        }
    }
}

/// "claude-opus-5-5", "Opus 5.5" and "opus-5.5-20260401" all read as
/// ("opus", "5.5"): the family word, then the version digits after it, with
/// release dates (8+ digits) skipped.
fn claude_family(model: &str) -> Option<(&'static str, String)> {
    let normalized = model.to_lowercase().replace(['-', '.', '_'], " ");
    let words: Vec<&str> = normalized.split_whitespace().collect();
    for family in ["fable", "mythos", "opus", "sonnet", "haiku"] {
        if let Some(at) = words.iter().position(|w| *w == family) {
            let version: Vec<&str> = words[at + 1..]
                .iter()
                .take_while(|w| w.chars().all(|c| c.is_ascii_digit()) && w.len() < 8)
                .copied()
                .collect();
            return Some((family, version.join(".")));
        }
    }
    None
}

fn claude_price(family: &str, version: &str) -> Price {
    match (family, version) {
        ("fable" | "mythos", "5.1") => Price {
            input: 10.0,
            output: 50.0,
            cache_read: 0.25,
        },
        ("fable" | "mythos", _) => Price::standard(10.0, 50.0),
        ("opus", "5.5") => Price {
            input: 4.0,
            output: 20.0,
            cache_read: 0.20,
        },
        ("opus", "5" | "4.8" | "4.7" | "4.6" | "4.5") => Price::standard(5.0, 25.0),
        ("opus", _) => Price::standard(15.0, 75.0),
        ("sonnet", "5.5" | "5") => Price {
            input: 2.0,
            output: 10.0,
            cache_read: 0.20,
        },
        ("sonnet", _) => Price::standard(3.0, 15.0),
        ("haiku", "5.5") => Price::standard(0.10, 0.50),
        ("haiku", "4.5") => Price::standard(1.0, 5.0),
        _ => Price::standard(0.8, 4.0),
    }
}

fn price_per_million(model: &str) -> Price {
    if let Some((family, version)) = claude_family(model) {
        return claude_price(family, &version);
    }
    let m = model.to_lowercase();
    if m.contains("gpt-5") || m.contains("gpt-4o") || m.contains("gpt-4") {
        Price::standard(5.0, 15.0)
    } else if m.contains("o1") || m.contains("o3") {
        Price::standard(15.0, 60.0)
    } else if m.contains("grok") {
        Price::standard(5.0, 15.0)
    } else if m.contains("gemini") {
        Price::standard(2.5, 10.0)
    } else {
        // Unknown / Cursor-style blended model.
        Price::standard(3.0, 12.0)
    }
}

/// Estimated USD for one bucket of tokens under `model` pricing.
pub fn estimate_cost_usd(model: &str, tokens: &TokenTotals) -> f64 {
    let p = price_per_million(model);
    (tokens.input as f64 * p.input
        + tokens.cache_read as f64 * p.cache_read
        + tokens.cache_write as f64 * p.input * 1.25
        + tokens.output as f64 * p.output)
        / 1_000_000.0
}

/// "1.23", "0.004" — dashboard copy, always with a $ in QML.
pub fn format_usd(value: f64) -> String {
    if value >= 1.0 {
        format!("{:.2}", value)
    } else if value >= 0.01 {
        format!("{:.3}", value)
    } else {
        format!("{:.4}", value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opus_costs_more_than_haiku() {
        let t = TokenTotals {
            input: 1_000_000,
            output: 500_000,
            cache_read: 0,
            cache_write: 0,
        };
        let opus = estimate_cost_usd("Opus 5.5", &t);
        let haiku = estimate_cost_usd("Haiku 4.5", &t);
        assert!(opus > haiku);
        // 1M in @ $4 + 0.5M out @ $20 = $14.00
        assert!((opus - 14.0).abs() < 0.01);
    }

    #[test]
    fn reads_ids_and_display_names_alike() {
        assert_eq!(
            claude_family("claude-opus-5-5"),
            Some(("opus", "5.5".into()))
        );
        assert_eq!(claude_family("Opus 5.5"), Some(("opus", "5.5".into())));
        assert_eq!(
            claude_family("claude-haiku-4-5-20251001"),
            Some(("haiku", "4.5".into()))
        );
        assert_eq!(claude_family("Fable 5.1"), Some(("fable", "5.1".into())));
        assert_eq!(
            price_per_million("Opus 5"),
            price_per_million("claude-opus-5")
        );
        assert_ne!(price_per_million("Opus 5"), price_per_million("Opus 5.5"));
    }

    #[test]
    fn cache_reads_use_the_model_rate() {
        let t = TokenTotals {
            input: 0,
            output: 0,
            cache_read: 1_000_000,
            cache_write: 0,
        };
        assert!((estimate_cost_usd("Opus 5.5", &t) - 0.20).abs() < 1e-9);
        assert!((estimate_cost_usd("Fable 5.1", &t) - 0.25).abs() < 1e-9);
        assert!((estimate_cost_usd("Opus 5", &t) - 0.50).abs() < 1e-9);
    }

    #[test]
    fn cache_read_is_cheap() {
        let fresh = TokenTotals {
            input: 1_000_000,
            output: 0,
            cache_read: 0,
            cache_write: 0,
        };
        let cached = TokenTotals {
            input: 0,
            output: 0,
            cache_read: 1_000_000,
            cache_write: 0,
        };
        let a = estimate_cost_usd("Sonnet", &fresh);
        let b = estimate_cost_usd("Sonnet", &cached);
        assert!(b < a);
    }

    #[test]
    fn formats_small_amounts() {
        assert_eq!(format_usd(12.345), "12.35");
        assert_eq!(format_usd(0.00456), "0.0046");
    }
}
