#!/usr/bin/env bash
# Builds the engine and the Swift shell, and puts them together as
# target/macos/Omega Notch.app, signed ad hoc for running on this Mac.
# Signing with a Developer ID and notarising are the release workflow's job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
BUNDLE_ID="app.wisething.omeganotch"
APP="$ROOT/target/macos/Omega Notch.app"

echo "Building engine…"
(cd "$ROOT" && cargo build --release -p omega-notch-engine)

echo "Building app…"
(cd "$ROOT/ui/macos" && swift build -c release --product OmegaNotch)
SHELL_BIN="$(cd "$ROOT/ui/macos" && swift build -c release --show-bin-path)/OmegaNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
install -m 755 "$SHELL_BIN" "$APP/Contents/MacOS/OmegaNotch"
install -m 755 "$ROOT/target/release/omega-notch-engine" "$APP/Contents/Helpers/omega-notch-engine"
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

# Inside out: the helper first, then the app around it.
codesign --force --options runtime --sign - "$APP/Contents/Helpers/omega-notch-engine"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"

echo "$APP"
