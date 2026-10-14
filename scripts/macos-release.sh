#!/usr/bin/env bash
# Builds the macOS download: the app, universal, signed with a Developer ID,
# notarised and stapled, inside a disk image that is itself signed, notarised
# and stapled, plus its checksum, in target/dist.
#
# Needs CODESIGN_IDENTITY set to a "Developer ID Application: …" identity in
# your Keychain, and Apple's notary service credentials, either:
#   NOTARY_PROFILE  a Keychain profile saved with
#                   `xcrun notarytool store-credentials` (on your Mac), or
#   NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER
#                   an App Store Connect API key: the .p8 file's path, its
#                   key ID and its issuer ID (in the release workflow).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
OUT="$ROOT/target/dist"
NAME="omega-notch-$VERSION-macos-universal"
DMG="$OUT/$NAME.dmg"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ]; then
  NOTARY=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is not set}" \
    --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER is not set}")
else
  echo "Set NOTARY_PROFILE, or NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER." >&2
  exit 1
fi

# Sends a file to Apple's notary service and waits for the verdict; on a
# rejection, prints Apple's log of what was wrong. A team's first submissions
# can take hours, hence the long wait.
notarise() {
  local result id status
  echo "Notarising $(basename "$1")…"
  result="$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 2h --output-format json)" || true
  id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
  status="$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
  if [ "$status" = "Accepted" ]; then return; fi
  if [ -z "$status" ]; then
    echo "No verdict on $(basename "$1"): $result" >&2
    [ -n "$id" ] && echo "Follow it with: xcrun notarytool info $id <credentials>" >&2
  else
    echo "Notarisation of $(basename "$1") ended as $status." >&2
    xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true
  fi
  exit 1
}

# Stapling fetches the ticket from Apple's CloudKit, and a dropped connection
# there fails the whole release after notarisation already passed. A few
# tries, a little apart.
staple() {
  local try
  for try in 1 2 3 4 5; do
    if xcrun stapler staple "$1"; then return; fi
    [ "$try" -eq 5 ] && break
    echo "Stapling $(basename "$1") failed; trying again in $((try * 15))s…" >&2
    sleep $((try * 15))
  done
  echo "Could not staple $(basename "$1")." >&2
  exit 1
}

RELEASE=1 "$ROOT/scripts/macos-bundle.sh"

# From here on, a copy of its own: another release build while Apple takes
# its time cannot change what is notarised and shipped.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto "$ROOT/target/macos-release/Omega Notch.app" "$WORK/Omega Notch.app"
APP="$WORK/Omega Notch.app"

# The app first, so its own ticket is stapled to it and it opens without a
# network check once it is copied out of the disk image.
ditto -c -k --keepParent "$APP" "$WORK/app.zip"
notarise "$WORK/app.zip"
staple "$APP"

echo "Packing the disk image…"
mkdir -p "$WORK/image" "$OUT"
ditto "$APP" "$WORK/image/Omega Notch.app"
ln -s /Applications "$WORK/image/Applications"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "Omega Notch" -srcfolder "$WORK/image" -fs HFS+ \
  -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
notarise "$DMG"
staple "$DMG"

# What Gatekeeper will say on someone else's Mac.
spctl --assess --type execute "$APP"
spctl --assess --type open --context context:primary-signature "$DMG"

(cd "$OUT" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
echo "$DMG"
