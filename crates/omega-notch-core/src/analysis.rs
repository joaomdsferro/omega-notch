//! A second opinion on usage from Claude itself, on request, through the
//! user's own `claude` CLI and subscription.
//!
//! Only numbers go out: totals, ratios, models, the cost per day and the
//! dearest sessions as "S1", "S2"… No chat title, folder, project name, id or
//! chat text is sent. `claude` runs with no tools, no MCP servers, no user or
//! project settings (so no hooks), in an empty folder, without saving the
//! session, and without the variables a parent Claude Code session sets.

use std::fmt::Write as _;
use std::process::Stdio;
use std::time::Duration;

use anyhow::Context;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::history::Scoped;
use crate::protocol::{Suggestion, TokenTotals};

/// The models the analysis can run on, as `claude --model` reads them.
pub const MODELS: [&str; 2] = ["sonnet", "opus"];
/// A slow answer is still an answer, up to this.
const TIMEOUT: Duration = Duration::from_secs(180);
/// Sessions sent, dearest first.
const TOP_SESSIONS: usize = 10;
/// The answer kept, in characters.
const MAX_ANSWER: usize = 6_000;

const SYSTEM: &str = "You review one developer's Claude Code usage statistics. \
Give 3 to 6 concrete recommendations, most valuable first, to spend less, work \
more efficiently and get better results. Base every claim on the numbers given, \
quote them, and say when something is uncertain. Prices are list-price \
estimates; the developer may be on a subscription. Answer in Markdown bullets, \
under 250 words, with no preamble.";

fn share(part: u64, whole: u64) -> String {
    if whole == 0 {
        return "0%".into();
    }
    format!("{:.0}%", 100.0 * part as f64 / whole as f64)
}

fn kinds(t: &TokenTotals) -> String {
    format!(
        "input {}, output {}, cache read {}, cache write {}",
        t.input, t.output, t.cache_read, t.cache_write
    )
}

/// What is sent: numbers only. `scope` says in a few words what the numbers
/// cover, without naming it.
pub fn summary(days: u32, scope: &str, scoped: &Scoped, suggestions: &[Suggestion]) -> String {
    let sessions = &scoped.matched;
    let mut totals = TokenTotals::default();
    let mut cost = 0.0;
    for s in sessions {
        totals.input += s.input;
        totals.output += s.output;
        totals.cache_read += s.cache_read;
        totals.cache_write += s.cache_write;
        cost += s.cost_usd;
    }
    let mut out = String::new();
    let _ = writeln!(out, "Claude Code usage over the last {days} days, {scope}.");
    let _ = writeln!(
        out,
        "Estimated cost ${cost:.2} over {} sessions. Tokens: {}.",
        sessions.len(),
        kinds(&totals)
    );
    let prompt = totals.input + totals.cache_read + totals.cache_write;
    let _ = writeln!(
        out,
        "Prompt tokens served from cache: {}. Cache reads per cache write: {:.1}.",
        share(totals.cache_read, prompt),
        totals.cache_read as f64 / totals.cache_write.max(1) as f64
    );

    let mut models: Vec<(String, f64, TokenTotals)> = Vec::new();
    for m in sessions.iter().flat_map(|s| &s.models) {
        let t = TokenTotals {
            input: m.input,
            output: m.output,
            cache_read: m.cache_read,
            cache_write: m.cache_write,
        };
        match models.iter_mut().find(|(name, ..)| *name == m.model) {
            Some((_, c, sum)) => {
                *c += m.cost_usd;
                sum.input += t.input;
                sum.output += t.output;
                sum.cache_read += t.cache_read;
                sum.cache_write += t.cache_write;
            }
            None => models.push((m.model.clone(), m.cost_usd, t)),
        }
    }
    models.sort_by(|a, b| b.1.total_cmp(&a.1));
    let _ = writeln!(out, "\nBy model:");
    for (name, c, t) in &models {
        let _ = writeln!(out, "- {name}: ${c:.2}; {}", kinds(t));
    }

    let mut costs_by_day: Vec<(&str, f64)> = Vec::new();
    for m in &scoped.models {
        match costs_by_day.iter_mut().find(|(d, _)| *d == m.date) {
            Some((_, c)) => *c += m.cost_usd,
            None => costs_by_day.push((&m.date, m.cost_usd)),
        }
    }
    costs_by_day.sort_by(|a, b| a.0.cmp(b.0));
    let _ = writeln!(out, "\nEstimated cost per active day:");
    for (day, c) in costs_by_day {
        let _ = writeln!(out, "- {day}: ${c:.2}");
    }

    let mut output_sorted: Vec<u64> = sessions.iter().map(|s| s.output).collect();
    output_sorted.sort_unstable();
    if let Some(median) = output_sorted.get(output_sorted.len() / 2) {
        let _ = writeln!(out, "\nMedian output per session: {median} tokens.");
    }
    let _ = writeln!(out, "Dearest sessions (anonymised):");
    for (i, s) in sessions.iter().take(TOP_SESSIONS).enumerate() {
        let names: Vec<&str> = s.models.iter().map(|m| m.model.as_str()).collect();
        let _ = writeln!(
            out,
            "- S{}: ${:.2}, models {}; {}; last active {}",
            i + 1,
            s.cost_usd,
            names.join(" + "),
            kinds(&TokenTotals {
                input: s.input,
                output: s.output,
                cache_read: s.cache_read,
                cache_write: s.cache_write,
            }),
            s.last_date
        );
    }

    if !suggestions.is_empty() {
        let _ = writeln!(
            out,
            "\nLocal rules already flagged (do not just repeat them):"
        );
        for s in suggestions {
            let saving = s
                .saving_usd
                .map(|v| format!(", about ${v:.2} to save"))
                .unwrap_or_default();
            let _ = writeln!(
                out,
                "- {} on {} session(s){saving}",
                s.kind,
                s.sessions.len()
            );
        }
    }
    out
}

/// Runs `claude -p` on the summary and returns its answer.
pub async fn ask(model: &str, summary: &str) -> anyhow::Result<String> {
    anyhow::ensure!(MODELS.contains(&model), "unknown model {model}");
    let claude =
        crate::jump::which("claude").context("Claude Code's claude command is not installed")?;
    // An empty folder of its own: no CLAUDE.md or project settings to pick up.
    let dir = crate::paths::app_data_dir().join("analysis");
    crate::paths::create_private_dir(&dir)?;

    let mut command = tokio::process::Command::new(claude);
    command
        .args([
            "-p",
            "--model",
            model,
            "--tools",
            "",
            "--strict-mcp-config",
            "--setting-sources",
            "project",
            "--no-session-persistence",
            "--output-format",
            "text",
            "--system-prompt",
            SYSTEM,
        ])
        .current_dir(&dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // Started from inside a Claude Code session, it would inherit markers
    // that change how it runs.
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("CLAUDE") {
            command.env_remove(key);
        }
    }
    let mut child = command.spawn().context("could not start claude")?;
    // The summary goes on stdin: with --tools "", a prompt argument is read
    // as one of the tools.
    let mut stdin = child.stdin.take().context("no stdin")?;
    stdin.write_all(summary.as_bytes()).await?;
    drop(stdin);
    let mut stdout = child.stdout.take().context("no stdout")?;
    let mut stderr = child.stderr.take().context("no stderr")?;

    let run = async {
        let mut answer = String::new();
        let mut errors = String::new();
        let (read_out, read_err) = tokio::join!(
            stdout.read_to_string(&mut answer),
            stderr.read_to_string(&mut errors)
        );
        read_out?;
        read_err?;
        let status = child.wait().await?;
        anyhow::Ok((status, answer, errors))
    };
    let (status, answer, errors) = tokio::time::timeout(TIMEOUT, run)
        .await
        .context("claude took too long to answer")??;
    if !status.success() {
        let reason = errors
            .lines()
            .chain(answer.lines())
            .find(|l| !l.trim().is_empty());
        anyhow::bail!("claude failed: {}", reason.unwrap_or("no reason given"));
    }
    let answer = answer.trim();
    anyhow::ensure!(!answer.is_empty(), "claude gave no answer");
    Ok(answer.chars().take(MAX_ANSWER).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ProviderId, SessionCost, SessionModelCost};

    #[test]
    fn the_summary_holds_numbers_and_no_names() {
        let session = SessionCost {
            provider: ProviderId::ClaudeCode,
            id: "5f1c2d3e-secret-id".into(),
            title: "Rewrite the payroll parser".into(),
            project: Some("acme-payroll".into()),
            cwd: Some("/Users/someone/acme-payroll".into()),
            surface: Some("CLI".into()),
            last_date: "2026-10-16".into(),
            input: 10,
            output: 2_000,
            cache_read: 900_000,
            cache_write: 100_000,
            total: 1_002_010,
            cost_usd: 1.5,
            models: vec![SessionModelCost {
                model: "Opus 5.5".into(),
                input: 10,
                output: 2_000,
                cache_read: 900_000,
                cache_write: 100_000,
                total: 1_002_010,
                cost_usd: 1.5,
            }],
        };
        let scoped = Scoped {
            matched: vec![session.clone()],
            sessions: vec![session],
            ..Scoped::default()
        };
        let flagged = vec![Suggestion {
            kind: "long_session".into(),
            title: "“Rewrite the payroll parser” re-read 45M tokens".into(),
            detail: String::new(),
            saving_usd: None,
            provider: ProviderId::ClaudeCode,
            sessions: vec!["5f1c2d3e-secret-id".into()],
        }];
        let text = summary(30, "the whole account", &scoped, &flagged);
        assert!(text.contains("$1.50"));
        assert!(text.contains("Opus 5.5"));
        assert!(text.contains("S1"));
        assert!(text.contains("long_session"));
        for secret in ["payroll", "acme", "/Users", "secret-id"] {
            assert!(!text.contains(secret), "{secret} leaked into: {text}");
        }
    }
}
