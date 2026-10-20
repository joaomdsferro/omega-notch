use std::time::Duration;

use chrono::Utc;
use serde_json::Value;

use super::traits::{Provider, ProviderError};
use crate::paths;
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

const INTERNAL_URL: &str = "https://ampcode.com/api/internal";

pub struct AmpProvider;

impl Provider for AmpProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Amp
    }
}

impl AmpProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let token = read_token(&paths::amp_secrets())?;

        let client = reqwest::Client::builder()
            .user_agent(crate::USER_AGENT)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| ProviderError::Other(e.into()))?;

        let response = client
            .post(INTERNAL_URL)
            .bearer_auth(&token)
            .header("content-type", "application/json")
            .header("accept", "application/json")
            .body(r#"{"jsonrpc":"2.0","method":"userDisplayBalanceInfo","params":{},"id":1}"#)
            .send()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        match response.status().as_u16() {
            401 | 403 => {
                return Err(ProviderError::NeedsAuth(
                    "Amp rejected the API key — run `amp login` again".into(),
                ));
            }
            429 => {
                return Err(ProviderError::Message(
                    "Amp rate-limited the usage request".into(),
                ));
            }
            status if !(200..300).contains(&status) => {
                let body = response.text().await.unwrap_or_default();
                return Err(ProviderError::Message(format!(
                    "Amp usage HTTP {status}: {body}"
                )));
            }
            _ => {}
        }

        let body: Value = response
            .json()
            .await
            .map_err(|e| ProviderError::Other(e.into()))?;

        parse_usage(&body)
    }
}

/// `~/.local/share/amp/secrets.json`. A secrets file can name several servers,
/// so only the ampcode.com keys are used — a proxy's key is never sent to
/// ampcode.com just because its prefix looks similar.
fn read_token(path: &std::path::Path) -> Result<String, ProviderError> {
    let raw = std::fs::read_to_string(path)
        .map_err(|_| ProviderError::NeedsAuth("No Amp sign-in — run `amp login`".into()))?;
    let root: Value = serde_json::from_str(&raw).map_err(|_| {
        ProviderError::Message("Amp's secrets.json is invalid — run `amp login` again".into())
    })?;

    for key in ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"] {
        if let Some(token) = root
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|token| !token.is_empty() && !token.contains(char::is_whitespace))
        {
            return Ok(token.to_string());
        }
    }

    Err(ProviderError::NeedsAuth(
        "Amp's secrets.json has no ampcode.com key — run `amp login` again".into(),
    ))
}

fn parse_usage(body: &Value) -> Result<UsageReading, ProviderError> {
    if body.get("ok").and_then(Value::as_bool) == Some(false)
        || body.get("error").is_some_and(|error| !error.is_null())
    {
        return Err(ProviderError::Message(format!(
            "Amp usage failed: {}",
            body.get("error").unwrap_or(&Value::Null)
        )));
    }

    let payload = body.get("result").unwrap_or(body);
    let display = payload
        .get("displayText")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            ProviderError::Message("Amp returned an unrecognized usage response".into())
        })?
        .replace("**", "");

    let (plan, windows) = parse_display(&display).ok_or_else(|| {
        ProviderError::Message("Amp returned an unrecognized usage response".into())
    })?;

    Ok(UsageReading {
        provider: ProviderId::Amp,
        display_name: ProviderId::Amp.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: Some(format!("{plan} plan")),
    })
}

/// Amp's internal endpoint returns display text, not structured quota fields.
/// Unknown wording fails visibly rather than turning a missing match into 0%.
fn parse_display(text: &str) -> Option<(String, Vec<UsageWindow>)> {
    let numbers = numbers(text);

    if let Some(tier) = after(text, "Tier:") {
        if tier.contains("agent usage $") && numbers.len() >= 6 {
            let [remaining, total, agent_pct, orb_remaining, orb_total, orb_pct] = [
                numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5],
            ];
            if total > 0.0
                && remaining <= total
                && orb_total > 0.0
                && orb_remaining <= orb_total
                && (0.0..=100.0).contains(&agent_pct)
                && (0.0..=100.0).contains(&orb_pct)
            {
                return Some((
                    plan_name(text)?,
                    vec![
                        UsageWindow {
                            label: "Agent usage".into(),
                            used_pct: 100.0 - agent_pct,
                            resets_at: None,
                        },
                        UsageWindow {
                            label: "Orb usage".into(),
                            used_pct: 100.0 - orb_pct,
                            resets_at: None,
                        },
                    ],
                ));
            }
        }
        return None;
    }

    if text.contains("Subscription:") {
        if numbers.len() < 2 {
            return None;
        }
        let (agent_pct, orb_pct) = (numbers[0], numbers[1]);
        if !(0.0..=100.0).contains(&agent_pct) || !(0.0..=100.0).contains(&orb_pct) {
            return None;
        }
        return Some((
            plan_name(text)?,
            vec![
                UsageWindow {
                    label: "Agent usage".into(),
                    used_pct: 100.0 - agent_pct,
                    resets_at: None,
                },
                UsageWindow {
                    label: "Orb usage".into(),
                    used_pct: 100.0 - orb_pct,
                    resets_at: None,
                },
            ],
        ));
    }

    if text.contains("Amp Free:") && numbers.len() >= 3 {
        let (remaining, total, _rate) = (numbers[0], numbers[1], numbers[2]);
        if total > 0.0 && remaining <= total {
            return Some((
                "Free".into(),
                vec![UsageWindow {
                    label: "Free allowance".into(),
                    used_pct: (total - remaining) / total * 100.0,
                    resets_at: None,
                }],
            ));
        }
    }

    None
}

/// `Amp <plan> Subscription: …` / `Amp <plan> Tier: …`.
fn plan_name(text: &str) -> Option<String> {
    let rest = text.trim_start().strip_prefix("Amp")?.trim_start();
    let end = ["Subscription:", "Tier:"]
        .into_iter()
        .filter_map(|marker| rest.find(marker))
        .min()?;
    let plan = rest[..end].trim();
    (!plan.is_empty()).then(|| plan.to_string())
}

fn after<'a>(text: &'a str, marker: &str) -> Option<&'a str> {
    text.split_once(marker).map(|(_, rest)| rest)
}

/// Decimal numbers in reading order, with thousands separators removed. The
/// text also carries days and hours; callers rely on the field order the
/// vendor's sentence uses.
fn numbers(text: &str) -> Vec<f64> {
    let mut out = Vec::new();
    let mut current = String::new();

    for ch in text.chars() {
        if ch.is_ascii_digit() || ch == '.' {
            current.push(ch);
        } else if ch == ',' {
            // The vendor's text is en-US: commas group thousands.
        } else if !current.is_empty() {
            push_number(&mut out, &current);
            current.clear();
        }
    }
    push_number(&mut out, &current);
    out
}

fn push_number(out: &mut Vec<f64>, text: &str) {
    let mut cleaned = String::with_capacity(text.len());
    let mut last_dot = false;
    for ch in text.chars() {
        if ch == '.' {
            if last_dot {
                continue;
            }
            last_dot = true;
        } else {
            last_dot = false;
        }
        cleaned.push(ch);
    }
    if let Ok(value) = cleaned.parse::<f64>() {
        out.push(value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(text: &str) -> (String, Vec<UsageWindow>) {
        parse_display(text).expect("parse")
    }

    #[test]
    fn reads_a_tier_plan_with_dollars_and_orb_hours() {
        let (plan, windows) = reading(
            "Amp Pro Tier: agent usage $42.50 of $50.00 remaining (85%), \
             orb usage 12h of 20h orb hours remaining (60%)\nresets upon renewal in 18 days",
        );
        assert_eq!(plan, "Pro");
        assert_eq!(windows.len(), 2);
        assert!((windows[0].used_pct - 15.0).abs() < 0.001);
        assert!((windows[1].used_pct - 40.0).abs() < 0.001);
    }

    #[test]
    fn reads_a_subscription_plan_from_percentages() {
        let (plan, windows) =
            reading("Amp Business Subscription: 72% other agent usage and 90% orb usage remaining");
        assert_eq!(plan, "Business");
        assert!((windows[0].used_pct - 28.0).abs() < 0.001);
        assert!((windows[1].used_pct - 10.0).abs() < 0.001);
    }

    #[test]
    fn reads_the_free_allowance() {
        let (plan, windows) = reading("Amp Free: $3.25/$10.00 remaining (replenishes +$2.00/hour)");
        assert_eq!(plan, "Free");
        assert!((windows[0].used_pct - 67.5).abs() < 0.001);
    }

    #[test]
    fn a_malformed_subscription_is_not_read_as_free() {
        assert!(parse_display("Amp Pro Subscription: n/a").is_none());
        assert!(parse_display("something else entirely").is_none());
    }
}
