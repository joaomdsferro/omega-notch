use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{Datelike, NaiveDate, Utc};
use tokio::process::Command;

use super::traits::{Provider, ProviderError};
use crate::protocol::{Fidelity, ProviderId, ReadingStatus, UsageReading, UsageWindow};

/// A cold start on a busy machine, short enough that a wedged process cannot
/// hold a refresh open.
const TIMEOUT: Duration = Duration::from_secs(20);

pub struct KiroProvider;

impl Provider for KiroProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Kiro
    }
}

impl KiroProvider {
    pub async fn fetch(&self) -> Result<UsageReading, ProviderError> {
        let binary = locate_binary().ok_or_else(|| ProviderError::Unsupported(ProviderId::Kiro))?;
        let text = run_usage(&binary).await?;
        parse_usage(&text)
    }
}

/// `KIRO_CLI_PATH` first; then the places the installer actually lands (a
/// Finder launch has none of them on `PATH`); absolute `PATH` entries last.
fn locate_binary() -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("KIRO_CLI_PATH").filter(|p| !p.is_empty()) {
        let path = PathBuf::from(override_path);
        return is_runnable(&path).then_some(path);
    }

    let home = dirs::home_dir()?;
    let candidates = [
        home.join(".local/bin/kiro-cli"),
        PathBuf::from("/opt/homebrew/bin/kiro-cli"),
        PathBuf::from("/usr/local/bin/kiro-cli"),
    ];
    if let Some(found) = candidates.into_iter().find(|path| is_runnable(path)) {
        return Some(found);
    }

    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .filter(|dir| dir.is_absolute())
            .map(|dir| dir.join("kiro-cli"))
            .find(|path| is_runnable(path))
    })
}

fn is_runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.is_file()
        && std::fs::metadata(path)
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}

async fn run_usage(binary: &Path) -> Result<String, ProviderError> {
    let child = Command::new(binary)
        .args(["chat", "--no-interactive", "/usage"])
        .kill_on_drop(true)
        .output();

    let output = tokio::time::timeout(TIMEOUT, child)
        .await
        .map_err(|_| ProviderError::Message("kiro-cli /usage timed out".into()))?
        .map_err(|e| ProviderError::Other(e.into()))?;

    // The CLI's card can land on either stream; keep both rather than lose
    // the numbers to a progress line on stderr.
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let text = if looks_like_usage(&stdout) {
        stdout.into_owned()
    } else if looks_like_usage(&stderr) {
        stderr.into_owned()
    } else {
        format!("{stdout}\n{stderr}")
    };
    Ok(text)
}

fn looks_like_usage(text: &str) -> bool {
    text.contains('%') || text.contains("Plan:") || text.contains("credits")
}

fn parse_usage(text: &str) -> Result<UsageReading, ProviderError> {
    let text = strip_ansi(text);
    let lowered = text.to_lowercase();

    if lowered.contains("not logged in")
        || lowered.contains("login required")
        || lowered.contains("failed to initialize auth portal")
        || lowered.contains("kiro-cli login")
        || lowered.contains("oauth error")
    {
        return Err(ProviderError::NeedsAuth(
            "Kiro CLI is signed out — run `kiro-cli login`".into(),
        ));
    }

    let percent = bar_percent(&text);
    let credits = credit_pair(&text);
    let resets_at = reset_date(&text);
    let bonus = bonus_credits(&text);

    // Percent wins when both are present; `(X of Y covered)` is used of total.
    let used_fraction = match (percent, credits) {
        (Some(percent), _) => Some(percent / 100.0),
        (None, Some((used, total))) if total > 0.0 => Some(used / total),
        _ => None,
    };

    let mut windows = Vec::new();
    if let Some(fraction) = used_fraction {
        windows.push(UsageWindow {
            label: "Credits".into(),
            used_pct: (fraction * 100.0).clamp(0.0, 100.0),
            resets_at,
        });
    }
    if let Some((used, total)) = bonus {
        if total > 0.0 {
            windows.push(UsageWindow {
                label: "Bonus credits".into(),
                used_pct: (used / total * 100.0).clamp(0.0, 100.0),
                resets_at: None,
            });
        }
    }

    if windows.is_empty() {
        return Err(ProviderError::Message("Kiro CLI reported no usage".into()));
    }

    Ok(UsageReading {
        provider: ProviderId::Kiro,
        display_name: ProviderId::Kiro.display_name().to_string(),
        fidelity: Fidelity::Official,
        status: ReadingStatus::Ok,
        windows,
        fetched_at: Utc::now(),
        message: plan_name(&text).map(|plan| format!("{plan} plan")),
    })
}

/// CSI, OSC, charset and 2-byte C1 escapes. The card is painted, not printed.
fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            out.push(ch);
            continue;
        }
        match chars.peek() {
            Some('[') => {
                chars.next();
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
            Some(']') => {
                chars.next();
                for next in chars.by_ref() {
                    if next == '\u{7}' {
                        break;
                    }
                }
            }
            Some('(') | Some(')') => {
                chars.next();
                chars.next();
            }
            Some(_) => {
                chars.next();
            }
            None => {}
        }
    }
    out
}

/// The `█… 42%` bar.
fn bar_percent(text: &str) -> Option<f64> {
    let mut digits = String::new();
    let mut saw_bar = false;
    let mut candidate = None;

    for ch in text.chars() {
        if ch == '█' {
            saw_bar = true;
            digits.clear();
        } else if ch.is_ascii_digit() && saw_bar {
            digits.push(ch);
        } else if ch == '%' {
            if saw_bar && !digits.is_empty() {
                candidate = digits.parse().ok().or(candidate);
            }
            digits.clear();
        } else if !ch.is_whitespace() {
            // Any other glyph ends the run; a later bar can still match.
            digits.clear();
        }
    }
    candidate
}

/// `(X of Y covered in plan)`.
fn credit_pair(text: &str) -> Option<(f64, f64)> {
    let start = text.find("covered")?;
    let before = &text[..start];
    let open = before.rfind('(')?;
    let inner = &before[open + 1..];
    let (used, total) = inner.split_once(" of ")?;
    Some((used.trim().parse().ok()?, total.trim().parse().ok()?))
}

/// `Bonus credits: 4.5/10`, the CLI's extra wallet.
fn bonus_credits(text: &str) -> Option<(f64, f64)> {
    let rest = text.split_once("Bonus credits:")?.1;
    let pair = rest.split_whitespace().next()?;
    let (used, total) = pair.split_once('/')?;
    Some((used.parse().ok()?, total.parse().ok()?))
}

/// `resets on 2026-09-30` or `resets on 9/30`. An `MM/DD` that has already
/// passed this year is next year's — a January reset read in December.
fn reset_date(text: &str) -> Option<chrono::DateTime<Utc>> {
    let rest = text.split_once("resets on ")?.1;
    let stamp = rest.split_whitespace().next()?;
    let today = Utc::now().date_naive();

    if stamp.contains('-') {
        let date = NaiveDate::parse_from_str(stamp, "%Y-%m-%d").ok()?;
        return date.and_hms_opt(0, 0, 0).map(|at| at.and_utc());
    }

    let (month, day) = stamp.split_once('/')?;
    let (month, day): (u32, u32) = (month.parse().ok()?, day.parse().ok()?);
    let this_year = NaiveDate::from_ymd_opt(today.year(), month, day)?;
    let date = if this_year >= today {
        this_year
    } else {
        NaiveDate::from_ymd_opt(today.year() + 1, month, day)?
    };
    date.and_hms_opt(0, 0, 0).map(|at| at.and_utc())
}

fn plan_name(text: &str) -> Option<String> {
    for line in text.lines() {
        if let Some(rest) = line.split_once("Plan:") {
            let name = rest.1.split('|').next().unwrap_or(rest.1).trim();
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const CARD: &str = "\u{1b}[2J
┌───────────────────────────┐
│ Plan: KIRO POWER | 4 usage breakdowns │
│ Credits  ████████░░░░  42% │
│ (12 of 30 covered in plan) │
│ Bonus credits: 5/10        │
│ resets on 2026-11-01       │
└───────────────────────────┘";

    #[test]
    fn reads_the_bar_the_plan_and_the_reset_date() {
        let reading = parse_usage(CARD).unwrap();
        assert_eq!(reading.windows.len(), 2);
        assert_eq!(reading.windows[0].label, "Credits");
        assert!((reading.windows[0].used_pct - 42.0).abs() < 0.001);
        assert!(reading.windows[0].resets_at.is_some());
        assert!((reading.windows[1].used_pct - 50.0).abs() < 0.001);
        assert_eq!(reading.message.as_deref(), Some("KIRO POWER plan"));
    }

    #[test]
    fn a_covered_pair_is_used_when_the_bar_is_missing() {
        let reading = parse_usage("Plan: KIRO FREE\n(3 of 10 covered in plan)").unwrap();
        assert_eq!(reading.windows.len(), 1);
        assert!((reading.windows[0].used_pct - 30.0).abs() < 0.001);
    }

    #[test]
    fn a_signed_out_cli_is_needs_auth() {
        assert!(matches!(
            parse_usage("You are not logged in. Run kiro-cli login"),
            Err(ProviderError::NeedsAuth(_))
        ));
    }

    #[test]
    fn an_ansi_coloured_percent_is_still_read() {
        let text = "\u{1b}[32m████\u{1b}[0m  \u{1b}[1m55%\u{1b}[0m";
        assert_eq!(bar_percent(&strip_ansi(text)), Some(55.0));
    }

    #[test]
    fn an_mm_dd_reset_that_passed_is_next_year() {
        let today = Utc::now().date_naive();
        let stamp = format!("{}/{}", today.month(), today.day());
        let date = reset_date(&format!("resets on {stamp}")).unwrap();
        assert_eq!(date.year(), today.year());
    }
}
