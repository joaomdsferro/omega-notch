# Contributing

Thanks for helping. Omega Notch is part of the Omega family of open-source apps, and anyone is welcome
to report a problem, suggest something, or send code.

## Reporting a bug

[Open an issue](https://github.com/joaomdsferro/omega-notch/issues/new/choose) with the bug template:
what you did, what you expected, what happened, the Omega Notch version, your distribution, and the
output of `omega-notch-engine doctor`.

**Never share tokens, `~/.claude/.credentials.json`, `~/.codex/auth.json`,
`~/.local/share/omega-notch/copilot.json`, or the contents of your chats.** Describe the problem
instead, or redact screenshots.

Security problems go privately, as [SECURITY.md](SECURITY.md) explains.

## Setting up

Requirements: Rust (stable), CMake, Ninja, Qt 6.5+ (Base, Declarative, Wayland) and LayerShellQt, on
KDE Plasma 6 / Wayland.

```sh
make run
```

To run a second instance next to an installed one, give it its own socket:

```sh
export OMEGA_NOTCH_SOCKET=$XDG_RUNTIME_DIR/omega-notch-dev.sock
./target/release/omega-notch-engine serve &
OMEGA_NOTCH_PREVIEW=claude_code ./ui/plasma/build/omega-notch-plasma
```

`OMEGA_NOTCH_PREVIEW=<provider id>` pins that provider's card open; `OMEGA_NOTCH_PREVIEW=settings`
opens Settings at launch. Both instances share `~/.config/omega-notch/config.json`.

Before sending changes:

```sh
cargo test -p omega-notch-core
make engine ui
```

## Formatting

Rust code is formatted with `rustfmt` (`cargo fmt`), with its default settings. This starts with
v0.0.3:

- **Until v0.0.3:** the existing code is not formatted yet. Run `rustfmt` only on files you add, so a
  pull request never mixes a change with unrelated reformatting.
- **In v0.0.3:** one commit formats the whole workspace with `cargo fmt` and changes nothing else. Its
  hash goes in `.git-blame-ignore-revs`, so `git blame` skips it. The release workflow starts running
  `cargo fmt --check`.
- **From then on:** every change must pass `cargo fmt --check`. Run `cargo fmt` before committing.

QML and C++ have no formatter: match the style of the file around you.

## Pull requests

- Branch from `main` and keep each pull request to one change.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `perf:`,
  `build:`, `docs:`, `chore:`.
- Match the code around you: its naming, comments and structure.
- Interface text is in plain English and short.
- Every clickable element shows a pointer cursor; disabled ones show `not-allowed`.
- The notch sits on screen all day, so it has to stay light: mention memory or CPU effects in the pull
  request when there are any.
- Providers read local files read-only, and only call the tool's own usage endpoint.

## Releasing

Bump `version` in `Cargo.toml` and `ui/plasma/CMakeLists.txt`, then push a tag such as `v0.0.2`. The
[release workflow](.github/workflows/release.yml) builds the download with `make dist` and attaches it
to a draft pre-release, which stays a draft until it is published on GitHub.

## Icons

The icons come from the Omega brand; see [packaging/icons/README.md](packaging/icons/README.md).

## License

Contributions are under the [MIT license](LICENSE).
