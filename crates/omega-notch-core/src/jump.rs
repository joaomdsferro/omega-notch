//! Clicking a chat takes you to it: the window (and, where the app allows,
//! the tab) that runs it, or a fresh one resuming it once its process is gone.
//!
//! - Live CLI sessions: the terminal window that owns the process is raised
//!   through a KWin script, and a bell is rung on the session's tty so the tab
//!   lights up. Terminals such as Ghostty expose no way to pick a tab from
//!   outside, so that is as close as it gets.
//! - VS Code sessions: the window showing the chat's folder is raised, then
//!   the extension's `vscode://anthropic.claude-code/open?session=` link opens
//!   that conversation in it.
//! - Finished CLI sessions: `claude --resume <id>` in a new terminal window.
//! - Claude Desktop and Cursor: their window is raised (Cursor on the chat's
//!   folder); neither offers a link to a single chat.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{bail, Context};
use tracing::info;

use crate::chats::{self, LiveSession};
use crate::paths;
use crate::protocol::ProviderId;

const VSCODE_SESSION_URI: &str = "vscode://anthropic.claude-code/open?session=";
/// Terminals tried, in order, for resuming a chat whose process is gone.
const TERMINALS: &[&str] = &["ghostty", "konsole", "kitty", "wezterm", "alacritty", "foot"];

/// What the UI knows about the clicked chat.
pub struct ChatTarget<'a> {
    pub provider: ProviderId,
    pub id: &'a str,
    pub cwd: Option<&'a str>,
    pub title: Option<&'a str>,
    pub surface: Option<&'a str>,
}

pub fn open_chat(target: &ChatTarget) -> anyhow::Result<()> {
    match target.provider {
        ProviderId::ClaudeCode => open_claude(target),
        ProviderId::Cursor => {
            match target.cwd {
                Some(cwd) => spawn("cursor", [cwd])?,
                None => spawn("cursor", [] as [&str; 0])?,
            }
            Ok(())
        }
        other => bail!("{other:?} chats cannot be opened"),
    }
}

fn open_claude(target: &ChatTarget) -> anyhow::Result<()> {
    if !valid_session_id(target.id) {
        bail!("not a Claude Code session id: {}", target.id);
    }
    let live = chats::read_claude_sessions()
        .unwrap_or_default()
        .into_iter()
        .find(|s| s.session_id.as_deref() == Some(target.id));
    let cwd = target
        .cwd
        .map(str::to_string)
        .or_else(|| live.as_ref().map(|s| s.cwd.clone()));
    let entrypoint = live
        .as_ref()
        .and_then(|s| s.entrypoint.clone())
        .unwrap_or_else(|| entrypoint_for(target.surface).to_string());
    info!(id = target.id, live = live.is_some(), %entrypoint, "opening chat");

    match (entrypoint.as_str(), live) {
        ("claude-vscode", _) => open_in_vscode(target.id, cwd.as_deref()),
        (_, Some(session)) => {
            let hints = window_hints(Some(&session), target.title, cwd.as_deref());
            raise_window(&ancestors(session.pid), &hints)?;
            ring_bell(session.pid);
            Ok(())
        }
        ("claude-desktop" | "claude-desktop-3p", None) => spawn("claude-desktop", [] as [&str; 0]),
        (_, None) => resume_in_terminal(target.id, cwd.as_deref()),
    }
}

/// The transcript only keeps the friendly surface name; map it back.
fn entrypoint_for(surface: Option<&str>) -> &'static str {
    match surface {
        Some("VS Code") => "claude-vscode",
        Some("Desktop") => "claude-desktop",
        _ => "cli",
    }
}

/// Session ids end up in a URL and a command line; only accept UUID-shaped ones.
fn valid_session_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

fn open_in_vscode(id: &str, cwd: Option<&str>) -> anyhow::Result<()> {
    // The extension opens links in the last focused window, so that has to
    // be the one showing this folder, or the chat would be resumed twice.
    let raised = cwd
        .map(chats::folder_name)
        .is_some_and(|folder| raise_vscode_window(&folder));
    if !raised {
        if let Some(cwd) = cwd.filter(|c| Path::new(c).is_dir()) {
            spawn("code", [cwd])?;
            // Give a new window time to come up before the link arrives.
            std::thread::sleep(Duration::from_millis(1500));
        }
    } else {
        std::thread::sleep(Duration::from_millis(150));
    }
    spawn("xdg-open", [format!("{VSCODE_SESSION_URI}{id}")])
}

fn resume_in_terminal(id: &str, cwd: Option<&str>) -> anyhow::Result<()> {
    let dir = cwd
        .filter(|c| Path::new(c).is_dir())
        .map(str::to_string)
        .or_else(|| dirs::home_dir().map(|h| h.display().to_string()))
        .unwrap_or_else(|| "/".into());
    let claude = which("claude").context("claude is not on PATH")?;
    let claude = claude.as_str();
    let terminal = std::env::var("TERMINAL")
        .ok()
        .and_then(|t| which(&t).map(|_| t))
        .or_else(|| TERMINALS.iter().find(|t| which(t).is_some()).map(|t| t.to_string()))
        .context("no terminal emulator found")?;
    let name = Path::new(&terminal)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(&terminal)
        .to_string();

    let args: Vec<String> = match name.as_str() {
        "ghostty" => vec![
            format!("--working-directory={dir}"),
            "-e".into(),
            claude.into(),
            "--resume".into(),
            id.into(),
        ],
        "konsole" => vec!["--workdir".into(), dir.clone(), "-e".into(), claude.into(), "--resume".into(), id.into()],
        "kitty" => vec!["--directory".into(), dir.clone(), claude.into(), "--resume".into(), id.into()],
        "wezterm" => vec!["start".into(), "--cwd".into(), dir.clone(), "--".into(), claude.into(), "--resume".into(), id.into()],
        "foot" => vec![format!("--working-directory={dir}"), claude.into(), "--resume".into(), id.into()],
        _ => vec!["--working-directory".into(), dir.clone(), "-e".into(), claude.into(), "--resume".into(), id.into()],
    };
    let mut command = Command::new(&terminal);
    command.args(&args).current_dir(&dir);
    detach(command)
}

/// Words a window caption may carry for this chat, best first.
fn window_hints(session: Option<&LiveSession>, title: Option<&str>, cwd: Option<&str>) -> Vec<String> {
    let mut hints = Vec::new();
    if let Some(session) = session {
        hints.push(session.name.clone());
    }
    if let Some(title) = title {
        hints.push(title.to_string());
    }
    if let Some(cwd) = cwd {
        hints.push(chats::folder_name(cwd));
    }
    hints.retain(|h| !h.trim().is_empty());
    hints
}

/// The process and its parents, nearest first: one of them owns the window
/// (the terminal emulator, VS Code, Claude Desktop…).
fn ancestors(pid: u32) -> Vec<u32> {
    let mut out = Vec::new();
    let mut current = pid;
    while current > 1 && out.len() < 32 {
        out.push(current);
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{current}/stat")) else {
            break;
        };
        // `pid (comm) state ppid …`; comm may hold spaces or parentheses.
        let Some(rest) = stat.rfind(')').map(|i| &stat[i + 1..]) else {
            break;
        };
        let Some(ppid) = rest.split_whitespace().nth(1).and_then(|p| p.parse().ok()) else {
            break;
        };
        current = ppid;
    }
    out
}

/// Raises the best window of the first pid in `pids` that has one. Among
/// that pid's windows the caption matching the earliest hint wins, then the
/// one stacked highest.
fn raise_window(pids: &[u32], hints: &[String]) -> anyhow::Result<()> {
    let script = format!(
        r#"
const pids = {pids};
const hints = {hints};
function score(w) {{
    const caption = (w.caption || "").toLowerCase();
    const parts = caption.split(" - ").map(p => p.trim());
    let best = 0;
    hints.forEach((h, i) => {{
        const weight = (hints.length - i) * 2;
        if (parts.includes(h)) best = Math.max(best, weight + 1);
        else if (caption.includes(h)) best = Math.max(best, weight);
    }});
    return best;
}}
let target = null;
for (const pid of pids) {{
    let top = -1;
    for (const w of workspace.stackingOrder) {{
        if (w.pid !== pid || !w.normalWindow) continue;
        const s = score(w);
        if (s >= top) {{ top = s; target = w; }}
    }}
    if (target) break;
}}
if (target) {{
    if (target.minimized) target.minimized = false;
    workspace.activeWindow = target;
}}
"#,
        pids = serde_json::to_string(pids)?,
        hints = serde_json::to_string(&hints.iter().map(|h| h.to_lowercase()).collect::<Vec<_>>())?,
    );
    run_kwin_script(&script)
}

/// Raises the VS Code window whose workspace is `folder`, through KWin's
/// window runner, which also tells us whether there is one.
fn raise_vscode_window(folder: &str) -> bool {
    let Ok(reply) = gdbus(&[
        "--dest", "org.kde.KWin", "--object-path", "/WindowsRunner",
        "--method", "org.kde.krunner1.Match", folder,
    ]) else {
        return false;
    };
    // `[('0_{uuid}', 'caption', …), …]`
    let found = reply.split("('").skip(1).find_map(|entry| {
        let (id, rest) = entry.split_once("', '")?;
        let caption = rest.split_once('\'')?.0;
        let mut parts = caption.split(" - ").map(str::trim);
        let is_vscode = caption.ends_with("Visual Studio Code");
        (is_vscode && parts.any(|p| p == folder)).then(|| id.to_string())
    });
    let Some(id) = found else { return false };
    gdbus(&[
        "--dest", "org.kde.KWin", "--object-path", "/WindowsRunner",
        "--method", "org.kde.krunner1.Run", &id, "",
    ])
    .is_ok()
}

fn run_kwin_script(source: &str) -> anyhow::Result<()> {
    let dir = paths::xdg_runtime_dir().join("omega-notch");
    std::fs::create_dir_all(&dir)?;
    let plugin = format!("omega-notch-jump-{}", uuid::Uuid::new_v4().simple());
    let path = dir.join(format!("{plugin}.js"));
    std::fs::File::create(&path)?.write_all(source.as_bytes())?;

    let result = (|| {
        let out = gdbus(&[
            "--dest", "org.kde.KWin", "--object-path", "/Scripting",
            "--method", "org.kde.kwin.Scripting.loadScript",
            &path.display().to_string(), &plugin,
        ])?;
        // `(7,)`
        let id: i64 = out
            .trim()
            .trim_start_matches('(')
            .trim_end_matches(')')
            .trim_end_matches(',')
            .parse()
            .with_context(|| format!("unexpected loadScript reply: {out}"))?;
        if id < 0 {
            bail!("KWin refused the script");
        }
        gdbus(&[
            "--dest", "org.kde.KWin", "--object-path", &format!("/Scripting/Script{id}"),
            "--method", "org.kde.kwin.Script.run",
        ])?;
        Ok(())
    })();

    let _ = gdbus(&[
        "--dest", "org.kde.KWin", "--object-path", "/Scripting",
        "--method", "org.kde.kwin.Scripting.unloadScript", &plugin,
    ]);
    let _ = std::fs::remove_file(&path);
    result
}

fn gdbus(args: &[&str]) -> anyhow::Result<String> {
    let out = Command::new("gdbus")
        .args(["call", "--session"])
        .args(args)
        .stdin(Stdio::null())
        .output()
        .context("gdbus is not installed")?;
    if !out.status.success() {
        bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Rings the terminal bell on the session's tty, which most terminals show on
/// its tab (Ghostty adds a bell to the title, Konsole marks the tab).
fn ring_bell(pid: u32) {
    let Ok(tty) = std::fs::read_link(format!("/proc/{pid}/fd/0")) else {
        return;
    };
    if !tty.starts_with("/dev/pts") {
        return;
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(&tty) {
        let _ = file.write_all(b"\x07");
    }
}

fn which(program: &str) -> Option<String> {
    if program.contains('/') {
        return Path::new(program).is_file().then(|| program.to_string());
    }
    let path = std::env::var_os("PATH")?;
    let home_bin = dirs::home_dir().map(|h| h.join(".local/bin"));
    std::env::split_paths(&path)
        .chain(home_bin)
        .map(|dir| dir.join(program))
        .find(|candidate| candidate.is_file())
        .map(|p| p.display().to_string())
}

fn spawn<I, S>(program: &str, args: I) -> anyhow::Result<()>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let resolved = which(program).with_context(|| format!("{program} is not installed"))?;
    let mut command = Command::new(resolved);
    command.args(args);
    detach(command)
}

/// Starts a program that outlives the click; a thread reaps it.
fn detach(mut command: Command) -> anyhow::Result<()> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_ids_are_uuid_shaped() {
        assert!(valid_session_id("5073f281-1cf8-48a8-9c37-42d7aae21f83"));
        assert!(!valid_session_id(""));
        assert!(!valid_session_id("abc; rm -rf ~"));
        assert!(!valid_session_id("x&prompt=hi"));
    }

    #[test]
    fn ancestors_start_with_the_process_itself() {
        let me = std::process::id();
        let chain = ancestors(me);
        assert_eq!(chain.first(), Some(&me));
        assert!(chain.len() >= 2);
    }
}
