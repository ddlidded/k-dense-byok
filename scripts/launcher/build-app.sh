#!/bin/bash
# Rebuild Kady.app from the sources in this directory.
#
#   scripts/launcher/build-app.sh
#
# Produces the full bundle at the repo root: outer stay-open applet (Dock
# icon, Cmd+Q, reopen), hidden inner supervisor applet, supervise.sh, and
# the compiled kady-window binary. Signs with the "Kady Self-Signed" identity
# when present (stable TCC grant across rebuilds), otherwise ad-hoc.
#
# To create the stable identity once:
#   Keychain Access → Certificate Assistant → Create a Certificate…
#   Name: "Kady Self-Signed", Type: Code Signing — OR use openssl/security.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/scripts/launcher"
APP="$ROOT/Kady.app"
INNER="$APP/Contents/Resources/KadySupervisor.app"
ICON_SRC="$ROOT/web/public/k-dense-logo.png"

[ -f "$ICON_SRC" ] || { echo "icon source missing: $ICON_SRC" >&2; exit 1; }
command -v osacompile >/dev/null || { echo "osacompile not found (macOS required)" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found — install Xcode CLT: xcode-select --install" >&2; exit 1; }

rm -rf "$APP"

# Outer applet — MUST stay open (OSAAppletStayOpen): a plain applet quits as
# soon as `on run` returns and its quit handler then kills everything.
osacompile -s -o "$APP" "$SRC/kady-main.applescript"
# Inner supervisor applet — exits when supervise.sh exits.
osacompile -o "$INNER" "$SRC/kady-inner.applescript"

# Our own plists (trimmed of osacompile's boilerplate privacy keys).
cp "$SRC/Kady-Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/KadySupervisor-Info.plist" "$INNER/Contents/Info.plist"

# Scripts + window binary live inside the supervisor bundle.
cp "$SRC/supervise.sh" "$INNER/Contents/Resources/supervise.sh"
chmod +x "$INNER/Contents/Resources/supervise.sh"
swiftc -O -o "$INNER/Contents/Resources/kady-window" "$SRC/kady-window.swift" \
	-framework Cocoa -framework WebKit
chmod +x "$INNER/Contents/Resources/kady-window"

# Icons for both bundles (inner uses the same icon file name osacompile made).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
	"256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
	set -- $spec
	sips -z "$1" "$1" "$ICON_SRC" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/applet.icns"
cp "$APP/Contents/Resources/applet.icns" "$INNER/Contents/Resources/applet.icns"
rm -rf "${ICONSET%/*}"

# osacompile leftovers we replace/don't need.
rm -f "$APP/Contents/Resources/Assets.car" "$APP/Contents/Resources/applet.rsrc" \
	"$INNER/Contents/Resources/Assets.car" "$INNER/Contents/Resources/applet.rsrc"

# Sign. A stable self-signed identity keeps the TCC (Documents-folder) grant
# across rebuilds; ad-hoc re-prompts whenever the binary changes.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Kady Self-Signed"; then
	codesign --force --deep --sign "Kady Self-Signed" "$APP"
else
	codesign --force --deep --sign - "$APP"
fi
codesign -v "$APP"
touch "$APP"
echo "Built $APP"
