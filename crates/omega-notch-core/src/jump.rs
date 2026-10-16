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
//!
//! On macOS, apps are opened by bundle id through `open`, since their command
//! line tools are often not installed. A live CLI session brings its terminal
//! app forward; picking its window or tab is left to the app shell.

use std::collections::HashMap;
use std::io::Write;
use std::path::Path;
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
    match target.provider {
        ProviderId::ClaudeCode => open_claude(target),
        ProviderId::Cursor => open_app(&CURSOR, target.cwd).map(|_| None),
        other => bail!("{other:?} chats cannot be opened"),
    }
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
        (_, None) => resume_in_terminal(target.id, cwd.as_deref()).map(|_| None),
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

fn resume_in_terminal(id: &str, cwd: Option<&str>) -> anyhow::Result<()> {
    let dir = cwd
        .filter(|c| Path::new(c).is_dir())
        .map(str::to_string)
        .or_else(|| dirs::home_dir().map(|h| h.display().to_string()))
        .unwrap_or_else(|| "/".into());
    let claude = which("claude").context("claude is not on PATH")?;
    let claude = claude.as_str();
    #[cfg(target_os = "macos")]
    if std::env::var("TERMINAL")
        .ok()
        .and_then(|t| which(&t))
        .is_none()
    {
        return resume_in_terminal_app(&dir, claude, id);
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

    let args: Vec<String> = match name.as_str() {
        "ghostty" => vec![
            format!("--working-directory={dir}"),
            "-e".into(),
            claude.into(),
            "--resume".into(),
            id.into(),
        ],
        "konsole" => vec![
            "--workdir".into(),
            dir.clone(),
            "-e".into(),
            claude.into(),
            "--resume".into(),
            id.into(),
        ],
        "kitty" => vec![
            "--directory".into(),
            dir.clone(),
            claude.into(),
            "--resume".into(),
            id.into(),
        ],
        "wezterm" => vec![
            "start".into(),
            "--cwd".into(),
            dir.clone(),
            "--".into(),
            claude.into(),
            "--resume".into(),
            id.into(),
        ],
        "foot" => vec![
            format!("--working-directory={dir}"),
            claude.into(),
            "--resume".into(),
            id.into(),
        ],
        _ => vec![
            "--working-directory".into(),
            dir.clone(),
            "-e".into(),
            claude.into(),
            "--resume".into(),
            id.into(),
        ],
    };
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

/// Opens a Terminal.app window running `claude --resume <id>` in `dir`. The
/// values reach AppleScript as arguments, and `quoted form of` quotes them
/// for the shell, so none of them is ever spliced into a script.
#[cfg(target_os = "macos")]
fn resume_in_terminal_app(dir: &str, claude: &str, id: &str) -> anyhow::Result<()> {
    const SCRIPT: &str = r#"on run argv
    set {dir, claude, sessionId} to argv
    tell application "Terminal"
        activate
        do script "cd " & quoted form of dir & " && " & quoted form of claude & " --resume " & quoted form of sessionId
    end tell
end run"#;
    let mut command = Command::new("/usr/bin/osascript");
    command.args(["-e", SCRIPT, dir, claude, id]);
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
/// the app runs a single session. `None` whenever it is not clear, so a chat
/// is never marked read by a guess.
pub fn session_in_window(
    pid: u32,
    title: Option<&str>,
    titles: &HashMap<String, String>,
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
    pick_session(&candidates, title)
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

fn pick_session(candidates: &[(String, Vec<String>)], title: Option<&str>) -> Option<String> {
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
    let mut winners = scored.iter().filter(|(score, _)| *score == top);
    let (_, id) = winners.next()?;
    winners.next().is_none().then(|| (*id).clone())
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
    let Ok(reply) = gdbus(&[
        "--dest",
        "org.kde.KWin",
        "--object-path",
        "/WindowsRunner",
        "--method",
        "org.kde.krunner1.Match",
        folder,
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

fn which(program: &str) -> Option<String> {
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

    #[test]
    fn the_window_in_front_names_its_session_or_none() {
        let hints = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
        let one = vec![("a".to_string(), hints(&["fix-login", "web"]))];
        let two = vec![
            ("a".to_string(), hints(&["fix-login", "web"])),
            ("b".to_string(), hints(&["omega-notch-f9", "omega-notch"])),
        ];
        // No title: only a lone session is certain.
        assert_eq!(pick_session(&one, None), Some("a".into()));
        assert_eq!(pick_session(&two, None), None);
        // A title picks the session it names.
        assert_eq!(
            pick_session(&two, Some("omega-notch — protocol.rs")),
            Some("b".into())
        );
        assert_eq!(pick_session(&two, Some("✳ fix-login")), Some("a".into()));
        // A title naming neither, even with one session, is another window.
        assert_eq!(pick_session(&one, Some("Downloads")), None);
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
            pick_session(
                &vscode,
                Some("Funcionalidades do omega notch — omega-notch")
            ),
            Some("b".into())
        );
        assert_eq!(
            pick_session(&vscode, Some("protocol.rs — omega-notch")),
            None
        );
        // Both named equally: not clear.
        let tie = vec![
            ("a".to_string(), hints(&["web"])),
            ("b".to_string(), hints(&["web"])),
        ];
        assert_eq!(pick_session(&tie, Some("web")), None);
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
}
