#!/usr/bin/env bash
# Builds the engine and the Swift shell, and puts them together as
# target/macos/Omega Notch.app, signed for running on this Mac.
#
# Set CODESIGN_IDENTITY to a code signing identity in your Keychain (an Apple
# Development certificate, say; `security find-identity -v -p codesigning`
# lists them) and macOS keeps your "Always Allow" for the Keychain across
# rebuilds. Without it the build is signed ad hoc, which macOS sees as a new
# program after every rebuild.
#
# RELEASE=1 builds the download instead, in target/macos-release: universal
# (Apple silicon and Intel), signed with a Developer ID and a secure
# timestamp, as notarisation needs, and with Sparkle's feed and public key
# so it updates itself. scripts/macos-release.sh does that, then notarises and
# packs the disk image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
BUNDLE_ID="app.wisething.omeganotch"
# Sparkle reads the latest release's appcast, and installs only what is signed
# with the private half of this key (kept in the `release` environment).
SPARKLE_FEED="https://github.com/joaomdsferro/omega-notch/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="fhC4LvVcbYHI+SJ4AW+aDjAXeDNd3minNXv5g+/GGKk="
IDENTITY="${CODESIGN_IDENTITY:--}"
RELEASE="${RELEASE:-0}"
# A release goes to its own folder. Replacing the files of an app that is
# running makes macOS see it as an unknown program, and ask for the Keychain
# password again.
if [ "$RELEASE" = 1 ]; then
  OUTDIR="$ROOT/target/macos-release"
else
  OUTDIR="$ROOT/target/macos"
fi
APP="$OUTDIR/Omega Notch.app"

if [ "$RELEASE" = 1 ]; then
  case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    *)
      echo "RELEASE=1 needs CODESIGN_IDENTITY set to a \"Developer ID Application: …\" identity." >&2
      exit 1
      ;;
  esac
  TIMESTAMP=--timestamp
  RUST_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
  SWIFT_ARCHS=(--arch arm64 --arch x86_64)
else
  TIMESTAMP=--timestamp=none
  RUST_TARGETS=()
  SWIFT_ARCHS=()
fi

echo "Building engine…"
if [ "$RELEASE" = 1 ]; then
  ENGINE="$OUTDIR/omega-notch-engine"
  mkdir -p "$OUTDIR"
  for target in "${RUST_TARGETS[@]}"; do
    (cd "$ROOT" && cargo build --release --locked -p omega-notch-engine --target "$target")
  done
  lipo -create -output "$ENGINE" \
    "$ROOT/target/aarch64-apple-darwin/release/omega-notch-engine" \
    "$ROOT/target/x86_64-apple-darwin/release/omega-notch-engine"
else
  ENGINE="$ROOT/target/release/omega-notch-engine"
  (cd "$ROOT" && cargo build --release -p omega-notch-engine)
fi

echo "Building app…"
(cd "$ROOT/ui/macos" && swift build -c release ${SWIFT_ARCHS[@]+"${SWIFT_ARCHS[@]}"} --product OmegaNotch)
BIN_DIR="$(cd "$ROOT/ui/macos" && swift build -c release ${SWIFT_ARCHS[@]+"${SWIFT_ARCHS[@]}"} --show-bin-path)"
SHELL_BIN="$BIN_DIR/OmegaNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
install -m 755 "$SHELL_BIN" "$APP/Contents/MacOS/OmegaNotch"
# Sparkle, where an app keeps its frameworks. Its XPC services are only for
# sandboxed apps, which this is not. The build folder's own paths go from the
# binary, so it neither looks there nor gives them away (a universal binary
# lists each once per architecture).
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
for rpath in $(otool -l "$APP/Contents/MacOS/OmegaNotch" | awk '$1 == "path" && $2 ~ /^\// && $2 !~ /^\/usr\// {print $2}' | sort -u); do
  install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/OmegaNotch"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/OmegaNotch"
install -m 755 "$ENGINE" "$APP/Contents/Helpers/omega-notch-engine"
install -m 755 "$ROOT/scripts/claude-hook.sh" "$APP/Contents/Resources/claude-hook.sh"

# The icon, from the PNGs the Linux build ships.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
PNG="$ROOT/packaging/icons/hicolor"
for pair in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 \
  512:256x256@2x 512:512x512; do
  cp "$PNG/${pair%%:*}x${pair%%:*}/apps/omega-notch.png" "$ICONSET/icon_${pair#*:}.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Omega Notch</string>
  <key>CFBundleDisplayName</key><string>Omega Notch</string>
  <key>CFBundleExecutable</key><string>OmegaNotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licence. Not affiliated with Anthropic, Anysphere, GitHub, OpenAI or xAI.</string>
  <key>NSAppleEventsUsageDescription</key><string>Omega Notch opens Terminal to resume a finished chat, and picks the tab a chat runs in when you switch that on.</string>
</dict>
</plist>
EOF
if [ "$RELEASE" = 1 ]; then
  if [ -z "$SPARKLE_PUBLIC_KEY" ]; then
    echo "SPARKLE_PUBLIC_KEY is empty: a release would not update itself." >&2
    exit 1
  fi
  # Checks once a day without asking first; installing still asks.
  plutil -insert SUFeedURL -string "$SPARKLE_FEED" "$APP/Contents/Info.plist"
  plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
  plutil -insert SUEnableAutomaticChecks -bool true "$APP/Contents/Info.plist"
fi

# The one entitlement: sending Apple Events, to pick a Terminal or iTerm2 tab
# (only when that is switched on in Settings, and after macOS asks).
ENTITLEMENTS="$(mktemp)"
cat > "$ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
EOF

# Inside out: Sparkle and the helper first, then the app around them. The identifiers are
# fixed so that, with a real identity, what macOS remembers stays the same from
# one build to the next. A local build has no timestamp, so it does not need
# Apple's timestamp server; a release needs one to be notarised.
echo "Signing with ${CODESIGN_IDENTITY:-an ad hoc signature}…"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for part in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$part"
done
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID.engine" "$APP/Contents/Helpers/omega-notch-engine"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"

echo "$APP"
