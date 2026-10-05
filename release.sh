#!/bin/bash
# Publishes a new Pulse version that every installed copy picks up automatically (Sparkle).
# Usage:  ./release.sh 1.1 "What changed in this version"
#
# Steps: bump version → universal build + sign → zip (for Sparkle) + DMG (for new installs)
#        → GitHub release with both files → add signed entry to appcast.xml → push.
# Needs: gh signed in, the Sparkle EdDSA key in your Keychain (made by generate_keys).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-Bug fixes and improvements.}"
REPO="troymeekhof/pulse"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Usage: ./release.sh <version, e.g. 1.1> [\"release notes\"]"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first."; exit 1; }
git fetch -q origin && [ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ] \
  || { echo "Local main differs from GitHub — pull/push first."; exit 1; }
gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 && { echo "v$VERSION already released."; exit 1; }

echo "▸ Version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $VERSION" Resources/Info.plist

DIST="${TMPDIR:-/tmp}/pulse-dist"
rm -rf "$DIST" && mkdir -p "$DIST"
DMG_OUT="$DIST/Pulse.dmg" ./build.sh --package
APP="${TMPDIR:-/tmp}/pulse-build/Pulse.app"
ZIP="$DIST/Pulse-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Sparkle signature: prints  sparkle:edSignature="…" length="…"
SIG_ATTRS="$("$SPARKLE_BIN/sign_update" "$ZIP")"

git commit -qam "Release $VERSION"
git push -q origin main
gh release create "v$VERSION" -R "$REPO" --target main --title "Pulse $VERSION" --notes "$NOTES" \
  "$ZIP" "$DIST/Pulse.dmg"

# Publish to the update feed only after the files are live on GitHub.
URL="https://github.com/$REPO/releases/download/v$VERSION/Pulse-$VERSION.zip"
VERSION="$VERSION" NOTES="$NOTES" URL="$URL" SIG_ATTRS="$SIG_ATTRS" python3 - <<'PY'
import os, html, email.utils
v, notes, url, sig = (os.environ[k] for k in ("VERSION", "NOTES", "URL", "SIG_ATTRS"))
path = "appcast.xml"
if not os.path.exists(path):
    open(path, "w").write('<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        '  <channel>\n    <title>Pulse</title>\n  </channel>\n</rss>\n')
item = f"""    <item>
      <title>Version {v}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{v}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{html.escape(notes)}</p>]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sig} />
    </item>
"""
s = open(path).read()
marker = "    <title>Pulse</title>\n"
open(path, "w").write(s.replace(marker, marker + item, 1))
PY

git add appcast.xml
git commit -qm "Appcast: $VERSION"
git push -q origin main

echo "▸ Released Pulse $VERSION"
echo "  Installed copies update within a day (or via gear → Check for Updates…)."
echo "  New installs: https://github.com/$REPO/releases/latest/download/Pulse.dmg"
