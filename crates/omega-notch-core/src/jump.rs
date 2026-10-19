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
//! - opencode: the TUI's terminal is raised (bell rung) when one runs the
//!   chat's folder; otherwise `opencode --session <id>` continues it.
//! - Claude Desktop and Codex Desktop: their window is raised (Codex on the
//!   chat's folder); neither offers a link to a single chat.
//! - Cursor: the window for the chat's folder is raised, or the Agents (glass)
//!   window when that is what is running; otherwise `cursor` opens the folder.
//!
//! On macOS, apps are opened by bundle id through `open`, since their command
//! line tools are often not installed. A live CLI session brings its terminal
//! app forward; picking its window or tab is left to the app shell.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{bail, Context};
use tracing::info;

use crate::chats::{self, LiveSession};
#[cfg(not(target_os = "macos"))]
use crate::paths;
use crate::platform;
use crate::protocol::ProviderId;

const VSCODE_SESSION_URI: &str = "vscode://anthropic.claude-code/open?session=";
/// Terminals tried, in order, for resuming a chat whose process is gone.
#[cfg(not(target_os = "macos"))]
const TERMINALS: &[&str] = &[
    "ghostty",
    "konsole",
    "kitty",
    "wezterm",
    "alacritty",
    "foot",
];

/// An app to open: its command on Linux, its bundle id on macOS.
struct App {
    command: &'static str,
    bundle_id: &'static str,
}

const VSCODE: App = App {
    command: "code",
    bundle_id: "com.microsoft.VSCode",
};
const CURSOR: App = App {
    command: "cursor",
    bundle_id: "com.todesktop.230313mzl4w4u92",
};
const CLAUDE_DESKTOP: App = App {
    command: "claude-desktop",
    bundle_id: "com.anthropic.claudefordesktop",
};
/// ChatGPT / Codex Desktop (`chatgpt` on Linux is the Codex launcher).
const CODEX_DESKTOP: App = App {
    command: "chatgpt",
    // `com.openai.chat` is ChatGPT Classic, which has no Codex.
    bundle_id: "com.openai.codex",
};

/// Opens `app`, on `folder` if given.
fn open_app(app: &App, folder: Option<&str>) -> anyhow::Result<()> {
    let folder = folder.into_iter();
    if cfg!(target_os = "macos") {
        let args = ["-b", app.bundle_id].into_iter().chain(folder);
        return spawn("open", args);
    }
    spawn(app.command, folder)
}

/// What the UI knows about the clicked chat.
pub struct ChatTarget<'a> {
    pub provider: ProviderId,
    pub id: &'a str,
    pub cwd: Option<&'a str>,
    pub title: Option<&'a str>,
    pub surface: Option<&'a str>,
}

/// What the app shell should bring forward once the engine has done its part:
/// on macOS, picking a window (and a terminal tab) takes AppKit and the
/// user's permission, which only the shell has.
#[derive(Debug, Clone, PartialEq)]
pub struct RaiseRequest {
    /// The session's process and its parents, nearest first.
    pub pids: Vec<u32>,
    /// Words the window's title may carry, best first.
    pub hints: Vec<String>,
    /// The session's terminal, such as `/dev/ttys003`.
    pub tty: Option<String>,
}

/// Opens the chat. On macOS, a live session also comes back as a request for
/// the shell to raise its window.
pub fn open_chat(target: &ChatTarget) -> anyhow::Result<Option<RaiseRequest>> {
    match target.provider.as_str() {
        "claude_code" => open_claude(target),
        "opencode" => open_opencode(target),
        "cursor" => open_cursor(target).map(|_| None),
        "codex" => open_app(&CODEX_DESKTOP, target.cwd).map(|_| None),
        other => bail!("{other} chats cannot be opened"),
    }
}

/// Brings the opencode TUI forward when it is the one working in the chat's
/// folder, ringing its terminal's bell so the tab lights up; otherwise
/// continues the session in a new terminal window.
fn open_opencode(target: &ChatTarget) -> anyhow::Result<Option<RaiseRequest>> {
    if let Some(pid) = target.cwd.and_then(live_opencode) {
        info!(id = target.id, pid, "opening live opencode session");
        let hints = window_hints(None, target.title, target.cwd);
        let pids = ancestors(pid);
        raise_window(&pids, &hints)?;
        ring_bell(pid);
        if cfg!(target_os = "macos") {
            let tty = platform::tty(pid).map(|t| t.display().to_string());
            return Ok(Some(RaiseRequest { pids, hints, tty }));
        }
        return Ok(None);
    }
    info!(id = target.id, live = false, "resuming opencode session");
    resume_in_terminal("opencode", &["--session", target.id], target.cwd).map(|_| None)
}

/// The opencode TUI process working in `cwd`, if one runs.
fn live_opencode(cwd: &str) -> Option<u32> {
    opencode_process(cwd, &platform::processes_named("opencode"))
}

/// opencode gives no process its session id; the folder it was started in is
/// what tells its instances apart.
fn opencode_process(cwd: &str, processes: &[(u32, PathBuf)]) -> Option<u32> {
    let wanted = Path::new(cwd).canonicalize().ok();
    processes
        .iter()
        .find(|(_, dir)| dir == Path::new(cwd) || wanted.as_deref() == Some(dir.as_path()))
        .map(|(pid, _)| *pid)
}

/// Brings Cursor forward. Spawning `cursor <folder>` alone often does nothing
/// when the Agents (glass) window is already up — its caption is just
/// "Cursor Agents", with no folder — so raise that window first.
fn open_cursor(target: &ChatTarget) -> anyhow::Result<()> {
    let folder = target.cwd.map(chats::folder_name);
    let cwd = target.cwd.filter(|c| Path::new(c).is_dir());
    info!(
        id = target.id,
        folder = folder.as_deref().unwrap_or(""),
        "opening Cursor chat"
    );
    if raise_cursor_window(folder.as_deref()) {
        return Ok(());
    }
    open_app(&CURSOR, cwd)?;
    // A second instance hands off to the running app; give it a beat, then
    // raise whatever Cursor window appeared (classic or Agents).
    std::thread::sleep(Duration::from_millis(400));
    let _ = raise_cursor_window(folder.as_deref());
    Ok(())
}

fn open_claude(target: &ChatTarget) -> anyhow::Result<Option<RaiseRequest>> {
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
        ("claude-vscode", _) => open_in_vscode(target.id, cwd.as_deref()).map(|_| None),
        (_, Some(session)) => {
            let hints = window_hints(Some(&session), target.title, cwd.as_deref());
            let pids = ancestors(session.pid);
            raise_window(&pids, &hints)?;
            ring_bell(session.pid);
            if cfg!(target_os = "macos") {
                let tty = platform::tty(session.pid).map(|t| t.display().to_string());
                return Ok(Some(RaiseRequest { pids, hints, tty }));
            }
            Ok(None)
        }
        ("claude-desktop" | "claude-desktop-3p", None) => {
            open_app(&CLAUDE_DESKTOP, None).map(|_| None)
        }
        (_, None) => {
            resume_in_terminal("claude", &["--resume", target.id], cwd.as_deref()).map(|_| None)
        }
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
            open_app(&VSCODE, Some(cwd))?;
            // Give a new window time to come up before the link arrives.
            std::thread::sleep(Duration::from_millis(1500));
        }
    } else {
        std::thread::sleep(Duration::from_millis(150));
    }
    spawn(platform::OPENER, [format!("{VSCODE_SESSION_URI}{id}")])
}

/// Opens a terminal window running `program` with `args` in `dir`; it is how
/// `claude --resume <id>` and `opencode --session <id>` continue a chat.
fn resume_in_terminal(program: &str, extra: &[&str], cwd: Option<&str>) -> anyhow::Result<()> {
    let dir = cwd
        .filter(|c| Path::new(c).is_dir())
        .map(str::to_string)
        .or_else(|| dirs::home_dir().map(|h| h.display().to_string()))
        .unwrap_or_else(|| "/".into());
    let resolved = which(program).with_context(|| format!("{program} is not on PATH"))?;
    let resolved = resolved.as_str();
    #[cfg(target_os = "macos")]
    if std::env::var("TERMINAL")
        .ok()
        .and_then(|t| which(&t))
        .is_none()
    {
        return resume_in_terminal_app(&dir, resolved, extra);
    }
    let terminal = std::env::var("TERMINAL")
        .ok()
        .and_then(|t| which(&t).map(|_| t))
        .or_else(default_terminal)
        .context("no terminal emulator found")?;
    let name = Path::new(&terminal)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(&terminal)
        .to_string();

    let mut args: Vec<String> = match name.as_str() {
        "ghostty" => vec![format!("--working-directory={dir}"), "-e".into()],
        "konsole" => vec!["--workdir".into(), dir.clone(), "-e".into()],
        "kitty" => vec!["--directory".into(), dir.clone()],
        "wezterm" => vec!["start".into(), "--cwd".into(), dir.clone(), "--".into()],
        "foot" => vec![format!("--working-directory={dir}")],
        _ => vec!["--working-directory".into(), dir.clone(), "-e".into()],
    };
    args.push(resolved.to_string());
    args.extend(extra.iter().map(|arg| (*arg).to_string()));

    let mut command = Command::new(&terminal);
    command.args(&args).current_dir(&dir);
    detach(command)
}

#[cfg(not(target_os = "macos"))]
fn default_terminal() -> Option<String> {
    TERMINALS
        .iter()
        .find(|t| which(t).is_some())
        .map(|t| t.to_string())
}

/// `$TERMINAL` is checked before this is reached; without it, Terminal.app.
#[cfg(target_os = "macos")]
fn default_terminal() -> Option<String> {
    None
}

/// Opens a Terminal.app window running `program` with `args` in `dir`. The
/// values reach AppleScript as arguments, and `quoted form of` quotes them
/// for the shell, so none of them is ever spliced into a script.
#[cfg(target_os = "macos")]
fn resume_in_terminal_app(dir: &str, program: &str, extra: &[&str]) -> anyhow::Result<()> {
    const SCRIPT: &str = r#"on run argv
    set {dir, program} to {item 1 of argv, item 2 of argv}
    set commandLine to "cd " & quoted form of dir & " && " & quoted form of program
    repeat with i from 3 to count of argv
        set commandLine to commandLine & " " & quoted form of (item i of argv)
    end repeat
    tell application "Terminal"
        activate
        do script commandLine
    end tell
end run"#;
    let mut command = Command::new("/usr/bin/osascript");
    command.args(["-e", SCRIPT, dir, program]);
    command.args(extra);
    detach(command)
}

/// Words a window caption may carry for this chat, best first.
fn window_hints(
    session: Option<&LiveSession>,
    title: Option<&str>,
    cwd: Option<&str>,
) -> Vec<String> {
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

/// The live Claude Code session the window in front shows: one whose
/// process runs under `pid` (the app owning that window). With the window's
/// `title`, the session whose chat title, name or folder it carries best
/// (`titles` maps session ids to chat titles: VS Code names its window after
/// the tab in front, and the chat's tab after the chat); without, only when
/// the app runs a single session. Sessions the caption fits equally well
/// (VS Code captions a chat's tab with the folder alone) are settled by
/// `unread`: the window holds one chat to read, so that is the one in front.
/// `None` whenever it is still not clear, so a chat is never marked read by a
/// guess.
pub fn session_in_window(
    pid: u32,
    title: Option<&str>,
    titles: &HashMap<String, String>,
    unread: &HashSet<String>,
) -> Option<String> {
    let candidates: Vec<(String, Vec<String>)> = chats::read_claude_sessions()?
        .into_iter()
        .filter(|s| ancestors(s.pid).contains(&pid))
        .filter_map(|s| {
            let id = s.session_id.clone()?;
            let mut hints = window_hints(Some(&s), None, Some(&s.cwd));
            if let Some(chat) = titles.get(&id) {
                hints.insert(0, chat.clone());
            }
            Some((id, hints))
        })
        .collect();
    let found = pick_session(&candidates, title, unread);
    // Counts only: the caption may name a private file or page.
    tracing::debug!(
        sessions = candidates.len(),
        titled = title.is_some_and(|t| !t.trim().is_empty()),
        matched = found.is_some(),
        "window in front"
    );
    found
}

/// How well a window caption fits a session's hints: an earlier hint counts
/// more, and a whole part of the caption more than a substring of it.
fn title_score(caption: &str, hints: &[String]) -> usize {
    let caption = caption.to_lowercase();
    let parts: Vec<&str> = caption
        .split([' ', '—', '–', '·', '|'])
        .filter(|p| !p.is_empty() && *p != "-")
        .collect();
    let mut best = 0;
    for (i, hint) in hints.iter().enumerate() {
        let hint = hint.trim().to_lowercase();
        if hint.is_empty() {
            continue;
        }
        let weight = (hints.len() - i) * 2;
        if parts.contains(&hint.as_str()) {
            best = best.max(weight + 1);
        } else if caption.contains(&hint) {
            best = best.max(weight);
        }
    }
    best
}

fn pick_session(
    candidates: &[(String, Vec<String>)],
    title: Option<&str>,
    unread: &HashSet<String>,
) -> Option<String> {
    let title = title.map(str::trim).filter(|t| !t.is_empty());
    let Some(title) = title else {
        return match candidates {
            [(id, _)] => Some(id.clone()),
            _ => None,
        };
    };
    let scored: Vec<(usize, &String)> = candidates
        .iter()
        .map(|(id, hints)| (title_score(title, hints), id))
        .collect();
    let top = scored
        .iter()
        .map(|(score, _)| *score)
        .max()
        .filter(|s| *s > 0)?;
    let winners: Vec<&String> = scored
        .iter()
        .filter(|(score, _)| *score == top)
        .map(|(_, id)| *id)
        .collect();
    let lone = |ids: &[&String]| match ids {
        [id] => Some((*id).clone()),
        _ => None,
    };
    lone(&winners).or_else(|| {
        let to_read: Vec<&String> = winners
            .into_iter()
            .filter(|id| unread.contains(*id))
            .collect();
        lone(&to_read)
    })
}

/// The process and its parents, nearest first: one of them owns the window
/// (the terminal emulator, VS Code, Claude Desktop…).
fn ancestors(pid: u32) -> Vec<u32> {
    let mut out = Vec::new();
    let mut current = pid;
    while current > 1 && out.len() < 32 {
        out.push(current);
        let Some(ppid) = platform::parent(current) else {
            break;
        };
        current = ppid;
    }
    out
}

/// Brings forward the app of the first pid in `pids` that runs from an app
/// bundle: the terminal or editor hosting the session. Which of its windows
/// comes forward is up to the app.
#[cfg(target_os = "macos")]
fn raise_window(pids: &[u32], _hints: &[String]) -> anyhow::Result<()> {
    let bundle = pids
        .iter()
        .find_map(|pid| platform::app_bundle(*pid))
        .context("the session runs in no app")?;
    spawn("open", [bundle])
}

/// The app shell picks the VS Code window on macOS; here there is no way to
/// tell which one shows the folder.
#[cfg(target_os = "macos")]
fn raise_vscode_window(_folder: &str) -> bool {
    false
}

/// Raises the best window of the first pid in `pids` that has one. Among
/// that pid's windows the caption matching the earliest hint wins, then the
/// one stacked highest.
#[cfg(not(target_os = "macos"))]
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
#[cfg(not(target_os = "macos"))]
fn raise_vscode_window(folder: &str) -> bool {
    raise_runner_window(folder, |caption| {
        caption.ends_with("Visual Studio Code")
            && caption.split(" - ").map(str::trim).any(|p| p == folder)
    })
}

/// Raises a Cursor window: the classic one for `folder` when that exists, else
/// the Agents (glass) window. Any plain Cursor window only when there is no
/// folder: one for another project would stop `cursor` opening this one.
#[cfg(not(target_os = "macos"))]
fn raise_cursor_window(folder: Option<&str>) -> bool {
    if let Some(folder) = folder {
        if raise_runner_window(folder, |caption| {
            is_cursor_window(caption)
                && caption != "Cursor Agents"
                && caption.split(" - ").map(str::trim).any(|p| p == folder)
        }) {
            return true;
        }
    }
    raise_runner_window("Cursor Agents", |caption| caption == "Cursor Agents")
        || (folder.is_none() && raise_runner_window("Cursor", is_cursor_window))
}

#[cfg(not(target_os = "macos"))]
fn is_cursor_window(caption: &str) -> bool {
    caption == "Cursor Agents" || caption == "Cursor" || caption.ends_with(" - Cursor")
}

/// Picks a KWin WindowsRunner match whose caption passes `ok`, and raises it.
#[cfg(not(target_os = "macos"))]
fn raise_runner_window(query: &str, ok: impl Fn(&str) -> bool) -> bool {
    let Ok(reply) = gdbus(&[
        "--dest",
        "org.kde.KWin",
        "--object-path",
        "/WindowsRunner",
        "--method",
        "org.kde.krunner1.Match",
        query,
    ]) else {
        return false;
    };
    // `[('0_{uuid}', 'caption', …), …]`
    let found = reply.split("('").skip(1).find_map(|entry| {
        let (id, rest) = entry.split_once("', '")?;
        let caption = rest.split_once('\'')?.0;
        ok(caption).then(|| id.to_string())
    });
    let Some(id) = found else { return false };
    gdbus(&[
        "--dest",
        "org.kde.KWin",
        "--object-path",
        "/WindowsRunner",
        "--method",
        "org.kde.krunner1.Run",
        &id,
        "",
    ])
    .is_ok()
}

/// macOS: the shell activates the app; there is no window picker here.
#[cfg(target_os = "macos")]
fn raise_cursor_window(_folder: Option<&str>) -> bool {
    false
}

#[cfg(not(target_os = "macos"))]
fn run_kwin_script(source: &str) -> anyhow::Result<()> {
    let dir = paths::runtime_dir().join("omega-notch");
    std::fs::create_dir_all(&dir)?;
    let plugin = format!("omega-notch-jump-{}", uuid::Uuid::new_v4().simple());
    let path = dir.join(format!("{plugin}.js"));
    std::fs::File::create(&path)?.write_all(source.as_bytes())?;

    let result = (|| {
        let out = gdbus(&[
            "--dest",
            "org.kde.KWin",
            "--object-path",
            "/Scripting",
            "--method",
            "org.kde.kwin.Scripting.loadScript",
            &path.display().to_string(),
            &plugin,
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
            "--dest",
            "org.kde.KWin",
            "--object-path",
            &format!("/Scripting/Script{id}"),
            "--method",
            "org.kde.kwin.Script.run",
        ])?;
        Ok(())
    })();

    let _ = gdbus(&[
        "--dest",
        "org.kde.KWin",
        "--object-path",
        "/Scripting",
        "--method",
        "org.kde.kwin.Scripting.unloadScript",
        &plugin,
    ]);
    let _ = std::fs::remove_file(&path);
    result
}

#[cfg(not(target_os = "macos"))]
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
    let Some(tty) = platform::tty(pid) else {
        return;
    };
    if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(&tty) {
        let _ = file.write_all(b"\x07");
    }
}

pub(crate) fn which(program: &str) -> Option<String> {
    if program.contains('/') {
        return Path::new(program).is_file().then(|| program.to_string());
    }
    // Apps started from the desktop get a short PATH, without Homebrew or
    // the places Claude Code installs itself.
    let path = std::env::var_os("PATH").unwrap_or_default();
    let home = dirs::home_dir();
    let extra = [".local/bin", ".claude/local"]
        .into_iter()
        .filter_map(|dir| home.as_ref().map(|h| h.join(dir)))
        .chain(["/opt/homebrew/bin", "/usr/local/bin"].map(std::path::PathBuf::from));
    // An empty entry would mean the current folder; never look there.
    std::env::split_paths(&path)
        .filter(|dir| dir.is_absolute())
        .chain(extra)
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

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn cursor_window_captions_match_classic_and_agents() {
        assert!(is_cursor_window("Cursor Agents"));
        assert!(is_cursor_window("Cursor"));
        assert!(is_cursor_window("omega-notch - Cursor"));
        assert!(!is_cursor_window("Installed GitHub App - Cursor - Brave"));
        assert!(!is_cursor_window("omega-notch - Visual Studio Code"));
    }

    #[test]
    fn a_tie_goes_to_the_only_chat_to_read() {
        let hints = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
        let set = |ids: &[&str]| ids.iter().map(|i| i.to_string()).collect::<HashSet<_>>();
        let two = vec![
            ("a".to_string(), hints(&["CodeRabbit", "omega-notch"])),
            ("b".to_string(), hints(&["Funcionalidades", "omega-notch"])),
        ];
        // VS Code captions the chat's tab with the folder alone.
        assert_eq!(
            pick_session(&two, Some("omega-notch"), &set(&["b"])),
            Some("b".into())
        );
        assert_eq!(
            pick_session(&two, Some("omega-notch"), &set(&["a", "b"])),
            None
        );
        assert_eq!(pick_session(&two, Some("omega-notch"), &set(&[])), None);
        // A window the caption does not fit still marks nothing.
        assert_eq!(pick_session(&two, Some("Downloads"), &set(&["b"])), None);
    }

    fn pick_session_(c: &[(String, Vec<String>)], title: Option<&str>) -> Option<String> {
        pick_session(c, title, &HashSet::new())
    }

    #[test]
    fn the_window_in_front_names_its_session_or_none() {
        let hints = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
        let one = vec![("a".to_string(), hints(&["fix-login", "web"]))];
        let two = vec![
            ("a".to_string(), hints(&["fix-login", "web"])),
            ("b".to_string(), hints(&["omega-notch-f9", "omega-notch"])),
        ];
        // No title: only a lone session is certain.
        assert_eq!(pick_session_(&one, None), Some("a".into()));
        assert_eq!(pick_session_(&two, None), None);
        // A title picks the session it names.
        assert_eq!(
            pick_session_(&two, Some("omega-notch — protocol.rs")),
            Some("b".into())
        );
        assert_eq!(pick_session_(&two, Some("✳ fix-login")), Some("a".into()));
        // A title naming neither, even with one session, is another window.
        assert_eq!(pick_session_(&one, Some("Downloads")), None);
        // Two chats in one VS Code folder: the folder ties them, the chat's
        // tab title in the window caption does not; another file in front
        // leaves it unclear.
        let vscode = vec![
            (
                "a".to_string(),
                hints(&["CodeRabbit no PR #21", "omega-notch-ff", "omega-notch"]),
            ),
            (
                "b".to_string(),
                hints(&[
                    "Funcionalidades do omega notch",
                    "omega-notch-f9",
                    "omega-notch",
                ]),
            ),
        ];
        assert_eq!(
            pick_session_(
                &vscode,
                Some("Funcionalidades do omega notch — omega-notch")
            ),
            Some("b".into())
        );
        assert_eq!(
            pick_session_(&vscode, Some("protocol.rs — omega-notch")),
            None
        );
        // Both named equally: not clear.
        let tie = vec![
            ("a".to_string(), hints(&["web"])),
            ("b".to_string(), hints(&["web"])),
        ];
        assert_eq!(pick_session_(&tie, Some("web")), None);
    }

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

    #[test]
    fn an_opencode_instance_is_matched_by_its_folder() {
        let processes = [
            (10, PathBuf::from("/home/me/web")),
            (11, PathBuf::from("/home/me/api")),
        ];
        assert_eq!(opencode_process("/home/me/web", &processes), Some(10));
        assert_eq!(opencode_process("/home/me/other", &processes), None);
    }
}
