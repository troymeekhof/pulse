#!/bin/bash
# Builds Pulse.app and optionally installs it or packages it for sharing.
# Usage:  ./build.sh            → builds ./Pulse.app (Apple Silicon)
#         ./build.sh --install  → builds, copies to /Applications, launches it
#         ./build.sh --package  → builds a universal app (Apple Silicon + Intel if possible)
#                                 and creates ~/Downloads/Pulse.dmg to send to someone
# Env:    SIGN_IDENTITY  codesign identity (default "-" = ad-hoc; set to "Developer ID Application: …" later)
#         DMG_OUT        where --package writes the DMG (default ~/Downloads/Pulse.dmg)
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Installing…"
  xcode-select --install || true
  echo "Re-run ./build.sh after the install finishes."
  exit 1
fi

echo "▸ Compiling (release, Apple Silicon)…"
swift build -c release --arch arm64 2>&1 | grep -v "^\[" || true
ARM=".build/arm64-apple-macosx/release/Pulse"
[ -x "$ARM" ] || ARM=".build/release/Pulse"
[ -x "$ARM" ] || { echo "Build failed — binary not found."; exit 1; }
BIN="$ARM"

if [ "$MODE" == "--package" ]; then
  echo "▸ Compiling Intel version…"
  swift build -c release --arch x86_64 2>&1 | grep -v "^\[" || true
  X86=".build/x86_64-apple-macosx/release/Pulse"
  if [ -x "$X86" ] && lipo -create "$ARM" "$X86" -output .build/Pulse-universal 2>/dev/null; then
    BIN=".build/Pulse-universal"
    echo "▸ Universal binary: $(lipo -archs "$BIN")"
  else
    echo "▸ Intel build not available — packaging Apple Silicon only (M1/M2/M3/M4 Macs)."
  fi
fi

# Assemble outside the project: ~/Documents syncs via iCloud, whose file attributes
# make codesign fail ("resource fork, Finder information, or similar detritus").
STAGE_DIR="${TMPDIR:-/tmp}/pulse-build"
APP="$STAGE_DIR/Pulse.app"
rm -rf "$APP" Pulse.app
mkdir -p "$STAGE_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Pulse"
# Sparkle (auto-updates). The SwiftPM xcframework slice is already universal.
ditto "$(dirname "$ARM")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Pulse.icns ] && cp Resources/Pulse.icns "$APP/Contents/Resources/Pulse.icns"
xattr -cr "$APP" 2>/dev/null || true

# Sign inside-out (Sparkle's helpers first, then the app). Ad-hoc by default so macOS lets
# it run and "Launch at Login" works. Hardened runtime only with a real identity — with
# ad-hoc signing, library validation would refuse to load Sparkle.framework.
IDENTITY="${SIGN_IDENTITY:--}"
CS=(codesign --force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && CS+=(--options runtime --timestamp)
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${CS[@]}" "$SPK/XPCServices/Installer.xpc"
"${CS[@]}" --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
"${CS[@]}" "$SPK/Autoupdate"
"${CS[@]}" "$SPK/Updater.app"
"${CS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${CS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "▸ Built and signed $APP"

if [ "$MODE" == "--install" ]; then
  pkill -x Pulse >/dev/null 2>&1 || true
  rm -rf "/Applications/Pulse.app"
  cp -R "$APP" /Applications/
  echo "▸ Installed to /Applications/Pulse.app"
  open -a /Applications/Pulse.app
  echo "▸ Pulse is running — look for the waveform icon in your menu bar."
fi

if [ "$MODE" == "--package" ]; then
  STAGE="$(mktemp -d)/Pulse"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/How to open Pulse.txt" <<'TXT'
PULSE — GPU, memory, power, network & disk monitor for your Mac's menu bar

INSTALL
1. Drag Pulse into the Applications folder (in this window).
2. Open Applications and double-click Pulse.

FIRST LAUNCH (one time only)
Pulse isn't from the App Store, so macOS will warn you the first time.
  • Click "Done" (or "OK") on the warning.
  • Open System Settings → Privacy & Security.
  • Scroll down to the message about "Pulse" and click "Open Anyway".
  • Confirm with your password or Touch ID, then click "Open".
After that it opens normally.

USING IT
Pulse lives in the menu bar (top-right of your screen) — no Dock icon.
Click it to see the dashboard. Gear icon = settings, including
"Launch at login". Power button in the popover quits it.

Requires macOS 13 Ventura or newer.
TXT
  OUT="${DMG_OUT:-$HOME/Downloads/Pulse.dmg}"
  rm -f "$OUT"
  hdiutil create -volname "Pulse" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
  rm -rf "$(dirname "$STAGE")"
  echo "▸ Created $OUT ($(du -h "$OUT" | cut -f1))"
  if [ -z "${DMG_OUT:-}" ]; then open -R "$OUT"; fi
fi
