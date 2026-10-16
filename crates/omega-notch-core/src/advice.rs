//! Suggestions for spending less and getting more, from local rules.
//!
//! Each rule reads the sessions on the dashboard (as narrowed there) or the
//! live chats, and says what to change, about which sessions, and roughly
//! what it would have saved at list prices when that can be told. Nothing
//! leaves the machine: the rules are plain arithmetic over what the history
//! already holds.

use crate::pricing;
use crate::protocol::{ChatSummary, SessionCost, SessionModelCost, Suggestion, TokenTotals};

/// A session that wrote less than this was a small job.
const SMALL_OUTPUT: u64 = 20_000;
/// Small jobs on a top model are worth a word from this many on.
const MIN_SMALL_SESSIONS: usize = 2;
/// Cache writes this big are worth looking at.
const CHURN_MIN_WRITES: u64 = 1_000_000;
/// A healthy session reads its cache many times over; under this many reads
/// per write, the cache is being rebuilt rather than reused.
const CHURN_READS_PER_WRITE: u64 = 3;
/// History re-read past this many tokens makes a session a long one.
const LONG_SESSION_READS: u64 = 30_000_000;
/// A live chat this full is near its limit.
const CONTEXT_FULL_PCT: f64 = 80.0;
/// Under this, a saving is not worth a suggestion.
const MIN_SAVING_USD: f64 = 1.0;
/// The model small jobs could run on instead.
const LIGHTER_MODEL: &str = "Sonnet 5.5";
/// At most this many, so the card stays short.
pub const MAX_SUGGESTIONS: usize = 5;

fn tokens(m: &SessionModelCost) -> TokenTotals {
    TokenTotals {
        input: m.input,
        output: m.output,
        cache_read: m.cache_read,
        cache_write: m.cache_write,
    }
}

fn is_top_model(model: &str) -> bool {
    matches!(
        pricing::model_family(model),
        Some("opus" | "fable" | "mythos")
    )
}

fn usd(value: f64) -> String {
    pricing::format_usd(value)
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// Every suggestion for these sessions and chats, likeliest saving first,
/// at most `MAX_SUGGESTIONS`.
pub fn suggest(sessions: &[SessionCost], chats: &[ChatSummary]) -> Vec<Suggestion> {
    let mut out: Vec<Suggestion> = [
        model_choice(sessions),
        cache_churn(sessions),
        long_session(sessions),
    ]
    .into_iter()
    .flatten()
    .chain(context_full(chats))
    .collect();
    out.sort_by(|a, b| {
        b.saving_usd
            .unwrap_or(0.0)
            .total_cmp(&a.saving_usd.unwrap_or(0.0))
    });
    out.truncate(MAX_SUGGESTIONS);
    out
}

/// Small jobs run on Opus or Fable: the same tokens on Sonnet cost far less.
fn model_choice(sessions: &[SessionCost]) -> Option<Suggestion> {
    let mut small: Vec<(&SessionCost, f64)> = sessions
        .iter()
        .filter(|s| s.output < SMALL_OUTPUT)
        .filter_map(|s| {
            let saving: f64 = s
                .models
                .iter()
                .filter(|m| is_top_model(&m.model))
                .map(|m| m.cost_usd - pricing::estimate_cost_usd(LIGHTER_MODEL, &tokens(m)))
                .sum();
            (saving > 0.0).then_some((s, saving))
        })
        .collect();
    if small.len() < MIN_SMALL_SESSIONS {
        return None;
    }
    let saving: f64 = small.iter().map(|(_, s)| s).sum();
    if saving < MIN_SAVING_USD {
        return None;
    }
    small.sort_by(|a, b| b.1.total_cmp(&a.1));
    Some(Suggestion {
        kind: "model_choice".into(),
        title: format!("{} ran on a top model", plural(small.len(), "small job", "small jobs")),
        detail: format!(
            "Each wrote under {}k tokens, yet ran on Opus or Fable. On {LIGHTER_MODEL} the same work would have cost about {} less. Switch with /model for quick questions and small edits, and keep the top model for hard problems.",
            SMALL_OUTPUT / 1000,
            usd(saving)
        ),
        saving_usd: Some(saving),
        provider: small[0].0.provider,
        sessions: small.iter().map(|(s, _)| s.id.clone()).collect(),
    })
}

/// Sessions that rebuild their prompt cache instead of reusing it: writes
/// cost 1.25x input, reads a tenth.
fn cache_churn(sessions: &[SessionCost]) -> Option<Suggestion> {
    let mut churned: Vec<(&SessionCost, f64)> = sessions
        .iter()
        .filter(|s| {
            s.cache_write >= CHURN_MIN_WRITES
                && s.cache_read < s.cache_write * CHURN_READS_PER_WRITE
        })
        .map(|s| {
            let extra: f64 = s
                .models
                .iter()
                .map(|m| {
                    let written = TokenTotals {
                        cache_write: m.cache_write,
                        ..TokenTotals::default()
                    };
                    let read = TokenTotals {
                        cache_read: m.cache_write,
                        ..TokenTotals::default()
                    };
                    pricing::estimate_cost_usd(&m.model, &written)
                        - pricing::estimate_cost_usd(&m.model, &read)
                })
                .sum();
            (s, extra)
        })
        .collect();
    if churned.is_empty() {
        return None;
    }
    // Most of a rebuild is unavoidable; a fair share of it is not.
    let saving: f64 = churned.iter().map(|(_, e)| e).sum::<f64>() / 2.0;
    if saving < MIN_SAVING_USD {
        return None;
    }
    churned.sort_by(|a, b| b.1.total_cmp(&a.1));
    Some(Suggestion {
        kind: "cache_churn".into(),
        title: format!(
            "{} kept rebuilding the prompt cache",
            plural(churned.len(), "session", "sessions")
        ),
        detail: format!(
            "They wrote nearly as much to the cache as they read back. The cache lapses after about five minutes idle, and editing CLAUDE.md or switching tools mid-chat rebuilds it. Shorter pauses and a stable setup would have saved up to about {}.",
            usd(saving)
        ),
        saving_usd: Some(saving),
        provider: churned[0].0.provider,
        sessions: churned.iter().map(|(s, _)| s.id.clone()).collect(),
    })
}

/// A session so long that every turn re-reads a huge history.
fn long_session(sessions: &[SessionCost]) -> Option<Suggestion> {
    let mut long: Vec<&SessionCost> = sessions
        .iter()
        .filter(|s| s.cache_read >= LONG_SESSION_READS)
        .collect();
    if long.is_empty() {
        return None;
    }
    long.sort_by_key(|s| std::cmp::Reverse(s.cache_read));
    let first = long[0];
    let more = if long.len() > 1 {
        format!(" ({} more like it)", long.len() - 1)
    } else {
        String::new()
    };
    Some(Suggestion {
        kind: "long_session".into(),
        title: format!("“{}” re-read {}M tokens of history", first.title, first.cache_read / 1_000_000),
        detail: format!(
            "Every turn sends the whole chat again{more}. A fresh chat per task, or /compact once a task is done, keeps each turn cheaper and the model focused on what matters now."
        ),
        saving_usd: None,
        provider: first.provider,
        sessions: long.iter().map(|s| s.id.clone()).collect(),
    })
}

/// A live chat near its context limit.
fn context_full(chats: &[ChatSummary]) -> Vec<Suggestion> {
    chats
        .iter()
        .filter(|c| c.live && c.context_pct.is_some_and(|p| p >= CONTEXT_FULL_PCT))
        .map(|c| Suggestion {
            kind: "context_full".into(),
            title: format!(
                "“{}” is {}% full",
                c.title,
                c.context_pct.unwrap_or(0.0).round() as i64
            ),
            detail: "Near the limit, answers lose track of earlier detail and each turn costs more. Run /compact now, or start a new chat from a short summary.".into(),
            saving_usd: None,
            provider: c.provider,
            sessions: vec![c.id.clone()],
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ProviderId;

    fn session(id: &str, model: &str, t: TokenTotals) -> SessionCost {
        let cost = pricing::estimate_cost_usd(model, &t);
        SessionCost {
            provider: ProviderId::ClaudeCode,
            id: id.into(),
            title: format!("Chat {id}"),
            project: None,
            cwd: None,
            surface: None,
            last_date: "2026-10-16".into(),
            input: t.input,
            output: t.output,
            cache_read: t.cache_read,
            cache_write: t.cache_write,
            total: t.total(),
            cost_usd: cost,
            models: vec![SessionModelCost {
                model: model.into(),
                input: t.input,
                output: t.output,
                cache_read: t.cache_read,
                cache_write: t.cache_write,
                total: t.total(),
                cost_usd: cost,
            }],
        }
    }

    fn t(input: u64, output: u64, cache_read: u64, cache_write: u64) -> TokenTotals {
        TokenTotals {
            input,
            output,
            cache_read,
            cache_write,
        }
    }

    #[test]
    fn small_jobs_on_opus_suggest_a_lighter_model() {
        let small = t(200_000, 5_000, 2_000_000, 300_000);
        let sessions = vec![
            session("a", "Opus 4.7", small),
            session("b", "Opus 4.7", small),
            // Big output: a real job for a top model.
            session("c", "Opus 4.7", t(200_000, 90_000, 2_000_000, 300_000)),
            // Already light.
            session("d", "Sonnet 5.5", small),
        ];
        let s = model_choice(&sessions).unwrap();
        assert_eq!(s.sessions, vec!["a".to_string(), "b".to_string()]);
        assert!(s.saving_usd.unwrap() > MIN_SAVING_USD);
        // One small job is not a habit.
        assert!(model_choice(&sessions[..1]).is_none());
    }

    #[test]
    fn a_cache_rebuilt_more_than_reused_is_churn() {
        let churn = session("a", "Opus 4.7", t(0, 0, 2_000_000, 1_500_000));
        let healthy = session("b", "Opus 4.7", t(0, 0, 40_000_000, 1_500_000));
        let s = cache_churn(&[churn, healthy]).unwrap();
        assert_eq!(s.sessions, vec!["a".to_string()]);
        assert!(s.saving_usd.unwrap() > 0.0);
        assert!(cache_churn(&[session("b", "Opus 4.7", t(0, 0, 40_000_000, 1_500_000))]).is_none());
    }

    #[test]
    fn a_huge_history_is_a_long_session() {
        let long = session("a", "Opus 4.7", t(0, 0, 45_000_000, 2_000_000));
        let s = long_session(&[long]).unwrap();
        assert!(s.title.contains("45M"));
        assert_eq!(s.saving_usd, None);
        assert!(long_session(&[session("b", "Opus 4.7", t(0, 0, 1_000_000, 0))]).is_none());
    }

    #[test]
    fn suggestions_come_dearest_first_and_capped() {
        let small = t(200_000, 5_000, 2_000_000, 300_000);
        let sessions = vec![
            session("a", "Opus 4.7", small),
            session("b", "Opus 4.7", small),
            session("c", "Opus 4.7", t(0, 0, 45_000_000, 2_000_000)),
        ];
        let all = suggest(&sessions, &[]);
        assert!(all.len() <= MAX_SUGGESTIONS);
        let savings: Vec<f64> = all.iter().map(|s| s.saving_usd.unwrap_or(0.0)).collect();
        assert!(savings.windows(2).all(|w| w[0] >= w[1]));
        assert!(all.iter().any(|s| s.kind == "long_session"));
    }
}
