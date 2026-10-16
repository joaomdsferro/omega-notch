#!/usr/bin/env bash
# Writes target/dist/appcast.xml: the feed Sparkle reads to update the app,
# with one item, this version's disk image, signed with Sparkle's EdDSA key.
# The release attaches it, and the app reads it from the latest release.
#
# The private key comes from SPARKLE_PRIVATE_KEY (in the release workflow) or,
# when that is unset, from your login Keychain, where `generate_keys` put it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
OUT="$ROOT/target/dist"
DMG_NAME="omega-notch-$VERSION-macos-universal.dmg"
DMG="$OUT/$DMG_NAME"
RELEASE_URL="https://github.com/joaomdsferro/omega-notch/releases"
SIGN_UPDATE="$ROOT/ui/macos/.build/artifacts/sparkle/Sparkle/bin/sign_update"

test -f "$DMG" || { echo "No $DMG_NAME in target/dist: run make macos-release first." >&2; exit 1; }
test -x "$SIGN_UPDATE" || (cd "$ROOT/ui/macos" && swift package resolve)

# Prints `sparkle:edSignature="…" length="…"`, ready for the enclosure.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
else
  signature="$("$SIGN_UPDATE" "$DMG")"
fi
case "$signature" in
  sparkle:edSignature=*length=*) ;;
  *) echo "sign_update did not sign $DMG_NAME: $signature" >&2; exit 1 ;;
esac

cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Omega Notch</title>
    <link>$RELEASE_URL</link>
    <item>
      <title>Omega Notch $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>What changed is in the <a href="$RELEASE_URL/tag/v$VERSION">release notes on GitHub</a>.</p>]]></description>
      <enclosure url="$RELEASE_URL/download/v$VERSION/$DMG_NAME" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT/appcast.xml"
echo "$OUT/appcast.xml"
