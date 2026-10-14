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

### On macOS

Requirements: Rust (stable) and Xcode 16 or later (for Swift and the macOS SDK), on macOS 14 or later.
The shell lives in `ui/macos`, a Swift package.

```sh
make macos                         # builds target/macos/Omega Notch.app
open "target/macos/Omega Notch.app"
```

The app starts the engine inside it, and logs the engine to `~/Library/Logs/Omega Notch/engine.log`.
Config, data and the socket live in `~/Library/Application Support/omega-notch/`. The first time the
engine reads the Claude Code sign-in, macOS asks for Keychain access. By default the build is signed ad
hoc, and macOS asks again after every rebuild. To sign it with a certificate of your own, so "Always
Allow" lasts across rebuilds, name it in `CODESIGN_IDENTITY`:

```sh
security find-identity -v -p codesigning     # lists the identities you have
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make macos
```

A free Apple Account in Xcode gives you an Apple Development certificate.

To work on the shell without bundling it, start an engine yourself and point the shell at it:

```sh
./target/release/omega-notch-engine serve &
cd ui/macos && OMEGA_NOTCH_PREVIEW=claude_code swift run
```

Notifications need the app bundle, so `swift run` only logs them. Before sending changes:

```sh
cargo test --workspace
(cd ui/macos && swift test)
```

## Formatting

Rust code is formatted with `rustfmt` (`cargo fmt`), with its default settings. Every change must pass
`cargo fmt --all --check`, which CI and the release workflow run, so run `cargo fmt` before committing.

The whole workspace was formatted in one commit for v0.0.3. It is listed in `.git-blame-ignore-revs`;
to have `git blame` skip it, run `git config blame.ignoreRevsFile .git-blame-ignore-revs` once.

QML, C++ and Swift have no enforced formatter: match the style of the file around you.

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

Bump `version` in `Cargo.toml` and `ui/plasma/CMakeLists.txt`, then push a tag such as `v0.0.3`. The
[release workflow](.github/workflows/release.yml) builds the Linux download with `make dist` and the
macOS disk image with `make macos-release`, and attaches both to a draft release, which stays a
draft until it is published on GitHub. Then update the version and `sha256` in
[joaomdsferro/homebrew-tap](https://github.com/joaomdsferro/homebrew-tap)'s `Casks/omega-notch.rb`
(the `.dmg.sha256` file in the release has it).

To check the build and the secrets without releasing anything, run the workflow by hand from the
Actions tab: it is a dry run unless you untick **dry run**.

The macOS app updates itself with [Sparkle](https://sparkle-project.org). The release attaches an
`appcast.xml` (written by `scripts/macos-appcast.sh`), and the app reads it from the latest release.
Each update is signed with an EdDSA key: its public half is `SPARKLE_PUBLIC_KEY` in
`scripts/macos-bundle.sh`, and its private half is the `SPARKLE_PRIVATE_KEY` secret. Building the
disk image on your Mac signs it with the key in your login Keychain, where Sparkle's `generate_keys`
keeps it. Losing the private key means no update can reach the apps already installed, so keep a
copy somewhere safe.

The macOS job signs with a Developer ID Application certificate and notarises with an App Store
Connect API key, both kept as secrets of the `release` environment (the workflow lists them). To build
the same disk image on your Mac, with that certificate in your Keychain and the API key saved once
with `xcrun notarytool store-credentials omega-notch`:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=omega-notch make macos-release
```

## Icons

The icons come from the Omega brand; see [packaging/icons/README.md](packaging/icons/README.md).

## License

Contributions are under the [MIT license](LICENSE).
