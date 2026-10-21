<div align="center">

<img src="docs/assets/icon.png" alt="Omega Notch" width="112" />

# Omega Notch

### Your AI coding tools' limits and live sessions, in a notch on your Mac or on KDE Plasma.

[![Release](https://img.shields.io/github/v/release/joaomdsferro/omega-notch?include_prereleases&style=flat-square&label=release&color=e59a1c)](https://github.com/joaomdsferro/omega-notch/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/joaomdsferro/omega-notch/ci.yml?branch=main&style=flat-square&label=ci)](https://github.com/joaomdsferro/omega-notch/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-555555?style=flat-square&logo=apple&logoColor=white)](#macos)
[![KDE Plasma 6](https://img.shields.io/badge/KDE%20Plasma-6-1d99f3?style=flat-square&logo=kde&logoColor=white)](#kde-plasma)
[![MIT license](https://img.shields.io/badge/license-MIT-f4c430?style=flat-square)](LICENSE)

</div>

Omega Notch is a small notch fused to an edge of your screen. It shows how much of each AI coding
tool's limit you have used, which sessions are working right now, and tells you when one finishes or
needs you. One Rust engine reads it all from your own computer; a native shell draws it, in Swift on
macOS and Qt 6 / QML on KDE Plasma (Wayland).

Works with **Claude Code, Cursor, GitHub Copilot, Codex, OpenCode, Claude Desktop, Grok Bot** and
[more](docs/providers.md).

> [!NOTE]
> Omega Notch is still young: expect rough edges and settings that change between versions. It is an
> unofficial tool, not affiliated with any of the tools it reads.

## Install

### macOS

Needs macOS 14 Sonoma or later.

```sh
brew install --cask joaomdsferro/tap/omega-notch
```

Or download the `.dmg` from the [latest release](https://github.com/joaomdsferro/omega-notch/releases).
The app is signed, notarised and updates itself.

### KDE Plasma

Needs KDE Plasma 6 on Wayland. On Arch-based distributions, download the `linux-x86_64.tar.gz` from the
[latest release](https://github.com/joaomdsferro/omega-notch/releases), then:

```sh
sudo pacman -S --needed qt6-base qt6-declarative qt6-wayland layer-shell-qt kidletime libnotify python
tar xzf omega-notch-*-linux-x86_64.tar.gz && cd omega-notch-*-linux-x86_64
./install.sh
```

It installs to `~/.local/bin` without `sudo` and starts with Plasma. On other distributions,
[build from source](CONTRIBUTING.md).

## Highlights

- **One ring per tool**, filling up as its limit goes, with an orbit while a session works and an
  amber pulse when one is waiting on you
- **Alerts** when a session finishes or asks something, and when a limit passes 80% or runs out
- **Recent chats** per tool, with tokens and model; click one to jump back to its window
- **A dashboard** with cost estimates and tokens over 7, 30 or 90 days, per model, tool and session,
  plus suggestions to spend less
- **Light on your machine**: the engine idles at about 1% CPU and parses transcripts incrementally

See every [feature](docs/features.md).

## Privacy

Everything is read locally, read-only. The only network calls go to each tool's own usage endpoint,
with the sign-in that tool already saved. There is no server of ours. [Details](docs/privacy.md).

## Documentation

- [Features](docs/features.md) and [providers](docs/providers.md): what is shown and where it comes from
- [FAQ](docs/faq.md): empty rings, other desktops, removing it, reporting a bug
- [How it works](docs/architecture.md) and the [socket protocol](protocol/README.md)
- [Claude Code hooks](docs/claude-hooks.md), for older Claude Code builds
- [Contributing](CONTRIBUTING.md), including building from source, and [Security](SECURITY.md)

## License

[MIT](LICENSE). Part of the open-source Omega family, alongside
[Omega Zap](https://github.com/joaomdsferro/omega-zap). Not affiliated with Anthropic, Anysphere,
Apple, GitHub, Microsoft, OpenAI or xAI; their names and marks belong to their owners.
