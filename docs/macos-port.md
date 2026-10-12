# Omega Notch on macOS: port plan

Status: **accepted** (2026-10-12, against v0.0.2). Nothing here is built yet.

Omega Notch was built Linux-first, for KDE Plasma 6 on Wayland, and has never run on macOS. This plan
brings it to macOS with a **native Swift / AppKit shell**. The Rust engine is shared: it keeps
reading the same files, and the IPC protocol stays the contract between engine and shell.

## Where it stands today

Checked on macOS 26.7 (Apple silicon), Rust 1.98, Swift 6.4:

- `cargo build -p omega-notch-engine` **builds**, and 27 of the 28 `omega-notch-core` tests pass.
  The one failing test is `jump::tests::ancestors_start_with_the_process_itself`, because it reads
  `/proc`.
- The Qt shell can't be ported: it depends on LayerShellQt (`ui/plasma/CMakeLists.txt`,
  `import org.kde.layershell` in `Main.qml`), which exists only on Wayland.

| Area | Linux-only part | Impact on macOS |
|---|---|---|
| `chats.rs` | Treats a session as live when `/proc/<pid>` exists | Every live session is dropped, so no ring ever reports working or waiting |
| `jump.rs` | Parent pids and the tty from `/proc`; window raising through KWin scripts and `gdbus`; `xdg-open`; Linux terminal list | Clicking a chat does nothing |
| `providers/claude_code.rs` | Reads `~/.claude/.credentials.json` | That file doesn't exist on macOS, where Claude Code keeps its sign-in in the login Keychain (item `Claude Code-credentials`), so Claude Code usage never loads |
| `paths.rs` | `xdg_*` helpers built on the `dirs` crate | Mostly works already, because `dirs` resolves to `~/Library/Application Support` (see below) |
| Socket | `$XDG_RUNTIME_DIR`, otherwise the temp folder | Works by accident through `$TMPDIR`; it needs a fixed path |
| Notifications | `notify-send` (libnotify), called from the Qt shell | Replaced by the shell |
| Install/launch | `install.sh`, `.desktop` autostart, Bash launcher with `python3` | Replaced by an app bundle and a login item |
| Release | Arch Linux container, `.tar.gz` only | Needs a macOS job |

How the `paths.rs` locations resolve on macOS:

| Path | Resolves to | Correct? |
|---|---|---|
| Cursor `state.vscdb` | `~/Library/Application Support/Cursor/User/globalStorage/` | ✅ |
| Claude Desktop | `~/Library/Application Support/Claude` | ✅ |
| VS Code product dirs | `~/Library/Application Support/Code`, … | ✅ |
| `~/.claude`, `~/.codex`, `~/.grokbot` | home-relative | ✅ |
| `github-copilot` | `~/Library/Application Support/github-copilot` | ❌ The editor plugins use `~/.config/github-copilot` on macOS too |
| opencode `auth.json` | `~/Library/Application Support/opencode` | ❌ opencode uses `~/.local/share/opencode` (to verify) |
| App config and data | Both under `~/Library/Application Support/omega-notch` | ✅ They share one folder, and the file names don't clash |

## Target architecture

```
Omega Notch.app/
  Contents/MacOS/Omega Notch          Swift shell (AppKit + SwiftUI), LSUIElement agent app
  Contents/Helpers/omega-notch-engine Rust engine, universal binary (arm64 + x86_64)
  Contents/Resources/…                icon, claude hook script
```

- **The shell starts and supervises the engine** as a child process. It restarts the engine if it
  exits, and stops it when the shell quits. This replaces the Bash launcher and its `python3` socket
  probe. macOS attributes the child's privacy prompts (Keychain, Accessibility, Automation) to the
  app, so the user sees "Omega Notch" in every prompt.
- **Login item:** `SMAppService.mainApp` (macOS 13+), toggled from Settings. No LaunchAgent plist.
- **IPC unchanged:** newline-delimited JSON over the same Unix socket (protocol v3, with an additive
  bump to v4 for the jump step below). The Swift client uses `NWConnection` with
  `NWEndpoint.unix(path:)`.
- **Socket path on macOS:** `~/Library/Application Support/omega-notch/omega-notch.sock`, in a
  folder created `0700`, with the socket set to `0600` after `bind`. It is deterministic for both
  sides whether the app is launched from Finder, from launchd or from a terminal (`$TMPDIR` is not
  guaranteed in every case). It stays under the 104-byte `sun_path` limit on macOS for normal user
  names. `OMEGA_NOTCH_SOCKET` still overrides it.
- **Minimum macOS: 14 (Sonoma).** Version 14 gives SwiftUI `@Observable`, Swift Charts and
  cooperative app activation (`NSApp.yieldActivation`), which raising another app's window needs.

### Why AppKit + SwiftUI rather than AppKit alone

The notch window itself has to be AppKit: a borderless, non-activating `NSPanel` at a level above
the menu bar, with `collectionBehavior` `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
.ignoresCycle]`. The views inside it (rings, cards, Settings, Dashboard) are a close match for the
existing QML and translate almost one to one into SwiftUI hosted in `NSHostingView`, with Swift
Charts for the dashboard. Drawing all of that in pure AppKit (`NSView` and Core Animation) is
possible, but it would mean writing roughly twice as much code for the same result. Recommendation:
**AppKit for windows, panels, menus, cursors and activation; SwiftUI for content.**

## The notch on macOS

- **Edges:** keep the four edges. Default to **top-centre on a screen with a hardware notch**,
  detected with `NSScreen.safeAreaInsets.top > 0` and `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea`, so the notch grows out of the real one. Use right-centre elsewhere, as
  today.
- **Click-through:** on Wayland the surface spans the whole edge and a mask sets the input region
  (`setInputRegion`). On macOS the panel is instead **sized to the notch plus the open card**, and
  its frame is animated as it expands. Everything outside the panel is simply not ours, so no mask is
  needed.
- **Screens:** `screen_name` in the config maps to `NSScreen.localizedName`. Listen for
  `NSApplication.didChangeScreenParametersNotification` and fall back to the main screen, matching
  what `placeOnScreen` does today.
- **Auto-hide and peek:** same behaviour. Hover uses a tracking area on the panel, plus a global
  `NSEvent` mouse monitor for the nub at the edge.
- **Cursors (repo rule):** every clickable element shows `NSCursor.pointingHand`, and every disabled
  one shows `NSCursor.operationNotAllowed`. Build one shared SwiftUI modifier (`.clickable(enabled:)`)
  so no view sets cursors by hand.

## Engine changes

All of them live behind `#[cfg(target_os = …)]` in a new `platform` module (`platform/linux.rs` and
`platform/macos.rs`). Callers keep one API, and the Linux behaviour stays unchanged.

1. **Process info** (`platform::process`):
   - `is_alive(pid)`: `kill(pid, 0)`, where `0` or `EPERM` mean the process is alive. This replaces
     `/proc/<pid>` in `chats.rs`.
   - `parent(pid)` and `tty(pid)`: on macOS, `proc_pidinfo(PROC_PIDTBSDINFO)` through `libc` or the
     `libproc` crate. `ancestors()` and `ring_bell()` use them, and `ring_bell` accepts `/dev/ttys*`
     as well as `/dev/pts/*`.
   - The `ancestors` test then passes on both systems.
2. **Paths:**
   - `github_copilot_dir()` is `~/.config/github-copilot` on every OS.
   - opencode's path is fixed once verified.
   - `socket_path()` and the runtime folder follow the rule above.
   - The `xdg_*` names become neutral (`config_home`, `data_home`, `runtime_dir`). This is a rename
     only.
3. **Claude Code sign-in from the Keychain:**
   - Read the generic password `Claude Code-credentials` through the Security framework, with the
     `security-framework` crate rather than shelling out to `security`, so the token never appears in
     a process list.
   - Keep the file as the first choice when it exists, as it does on Linux.
   - The token stays in memory only: it is never logged, never written to disk and never sent
     anywhere but the usage endpoint the provider already calls.
   - macOS asks the user once and remembers "Always Allow" for that **code signature**. An unsigned
     or re-signed engine asks again after every update, which is one more reason to sign (Phase 0).
4. **Jump (opening a chat):**
   - The engine still decides what to open, because the session lookup, entry point and hints don't
     change. On macOS it uses `/usr/bin/open` where Linux uses `xdg-open`, and `open -b <bundle id>`
     for VS Code (`com.microsoft.VSCode`), Cursor and Claude Desktop. These GUI apps' CLIs
     (`code`, `cursor`) are often missing from `PATH`.
   - Raising **a particular window** needs AppKit and Accessibility, so on macOS that moves to the
     shell. A new server message, `raise_window {pids, hints}` (protocol v4, additive), tells the
     shell which window to bring forward. The Linux shell never receives it, because Linux keeps the
     KWin path.
   - The shell activates the app with `NSRunningApplication` and cooperative activation. If the
     user has granted Accessibility, it then raises the window whose `AXTitle` matches the best
     hint. Without Accessibility it still brings the right app forward.
   - The extra step, opt-in from Settings with its own Automation prompt, selects the exact
     **tab** in Terminal.app and iTerm2 by matching the session's tty through AppleScript. That's
     better than Linux, where the bell is the closest we get.
   - Resuming a finished session works through Terminal.app (`do script`), iTerm2, Ghostty, kitty,
     WezTerm or Alacritty. How Ghostty starts with a command on macOS still needs verifying.
     **`cwd` is passed as an argument or quoted with AppleScript's `quoted form of`, never spliced
     into a shell string.** The session id is already limited to UUID characters
     (`valid_session_id`).
5. **`PATH`:** apps started from Finder or launchd get only `/usr/bin:/bin:/usr/sbin:/sbin`.
   `which()` also searches `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and
   `~/.claude/local`, so `claude` is found.
6. **`doctor`** prints the macOS locations, and says whether the Keychain item is **present**,
   without reading the secret.

## Swift shell

- **Layout:**
  - Code: `ui/macos/` as a SwiftPM package with `OmegaNotchKit` (client, models, view models) and
    `OmegaNotch` (app), plus tests.
  - Bundle: `make macos` assembles `Omega Notch.app` (Info.plist, `.icns`, the engine in `Helpers/`)
    and signs it.
  - There is no `.xcodeproj` in the repository, so diffs stay reviewable, and the app still opens in
    Xcode through `Package.swift`.
- **Protocol models:** `Codable` structs that mirror `protocol/README.md`. To keep the two
  implementations from drifting, a Rust test writes one JSON fixture per message to
  `protocol/fixtures/`, and the Swift tests decode every fixture. CI runs both.
- **Feature parity, mapped from QML:**
  - `Main.qml` → `NotchPanel`, with `NotchShape`, `ProviderRing` and `DetailCard`
  - `SettingsWindow.qml` → `SettingsWindow`
  - `DashboardWindow.qml` and the `Dash*` views → `DashboardWindow`, with Swift Charts
  - `CopilotSignIn.qml` → `NSPasteboard` plus `NSWorkspace.open`
  - `OMEGA_NOTCH_PREVIEW` keeps working, for development
- **Notifications:** `UNUserNotificationCenter`. The app asks for permission the first time it
  needs it and respects the existing alerts and sound settings. It needs the real bundle, so it
  isn't available under `swift run`.
- **Style:** `swift-format` with its default settings on all Swift code, since every file is new.
  That matches the Rust rule of formatting only new files until v0.0.3.

## Packaging and release

- **Universal engine:** build `aarch64-apple-darwin` and `x86_64-apple-darwin`, then combine them with
  `lipo`. The shell is built universal too.
- **Signing and notarisation:**
  - Sign with a Developer ID Application certificate and the **hardened runtime**, inside out
    (engine first, then the app). Add no extra entitlements: no `disable-library-validation`, no JIT.
  - Notarise with `notarytool`, staple the ticket, and ship a `.dmg` with its `.sha256`, as the Linux
    tarball does.
- **CI:** a `macos` job in `release.yml` on `macos-15`, next to the existing Linux job, plus a
  `cargo test` and `swift test` check on pull requests.
  - The signing certificate (`.p12`) and the App Store Connect API key are kept as **secrets of a
    protected GitHub environment** that only the owner can approve. A pull request from a fork never
    sees them.
  - Third-party actions are pinned to a commit SHA.
- **Later:** a Homebrew cask, once the notarised `.dmg` is stable.
- **Uninstall:** quit the app, delete it and turn off the login item. The README lists the data
  folder (`~/Library/Application Support/omega-notch`) for anyone who wants it gone too.

## Security and privacy

The port moves no data anywhere new. The engine still reads local files and calls only each
provider's own usage endpoint. What changes:

- **Keychain access** is limited to one read-only item. Users see a system prompt for it, and the
  README explains why.
- **Accessibility and Automation** are optional, requested only when the user first opens a chat that
  needs them, and explained in Settings. Without them, opening a chat falls back to bringing the app
  forward.
- **Socket:** a `0700` folder and a `0600` socket, so other local users can't connect. Today's Linux
  build relies on `$XDG_RUNTIME_DIR` being `0700`.
- **Signing** means users can verify that the build they run is the one CI produced. Gatekeeper and
  notarisation do the same check automatically.
- **Found while planning, not part of the port:** the hook server (`127.0.0.1:17337`) accepts any
  body as JSON without checking `Content-Type` or `Origin`. A web page could therefore send a
  "simple" cross-origin `POST` and fake session events: spurious notifications and ring states, with
  no data exposed. This affects Linux as well. It should be fixed separately, by requiring
  `application/json` and rejecting requests that carry an `Origin`, and reported through
  [SECURITY.md](../SECURITY.md) if the owner wants it tracked as a vulnerability.

## Phases

Each phase is one or more pull requests from its own branch, reviewed and merged by the owner.

| # | Phase | Main changes | Size |
|---|---|---|---|
| 0 | Decisions | Taken, see [Decisions](#decisions) (one left for Phase 4) | — |
| 1 | Engine runs on macOS | `platform` module, paths, socket permissions, Keychain, `PATH`, `doctor`; `cargo test` on a macOS CI runner | S–M |
| 2 | Shell skeleton | SwiftPM package, protocol client and fixtures, engine supervision, notch panel with rings and peek | M |
| 3 | Feature parity | Cards, chats, Settings, Dashboard, Copilot sign-in, notifications, screens and edges, login item | L |
| 4 | Jump on macOS | `open`-based launching, `raise_window` (protocol v4), Accessibility; optional Terminal/iTerm2 tab selection | M |
| 5 | Release | `make macos`, signing, notarisation, `.dmg`, `release.yml` job | M |
| 6 | Docs | README (platform badge, install, privacy prompts), `CONTRIBUTING.md` (macOS setup), `protocol/README.md` (socket per OS, v4) | S |

Phase 1 helps Linux too: it adds `is_alive` without `/proc` and tightens the socket permissions. It
can merge before any Swift code exists.

## Decisions

Taken by the owner on 2026-10-12:

1. **Signed and notarised from the first macOS release.** The owner's existing personal Apple
   Developer account is used. Its Developer ID certificate also signs other apps, so CI gets a
   **dedicated App Store Connect API key** for this repository, which can be revoked without touching
   anything else. The key and the certificate live only in the protected GitHub environment.
2. **Bundle identifier: `app.wisething.omeganotch`.** It is permanent from the first release.
3. **Minimum macOS 14 (Sonoma).**
4. **Default position: top-centre around the hardware notch**, falling back to the right edge on
   screens without one.

Still open:

5. **Terminal tab selection** (Phase 4): is it worth the extra Automation prompt? This can wait
   until Phase 4.
