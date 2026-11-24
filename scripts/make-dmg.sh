#!/bin/sh
# Package dist/DockDesk.app into dist/DockDesk-<version>.dmg (app plus an Applications shortcut).
# Usage: scripts/make-dmg.sh <version>     Run scripts/build-app.sh first.
set -e
cd "$(dirname "$0")/.."
VERSION="${1:?usage: make-dmg.sh <version>}"
APP=dist/DockDesk.app
DMG="dist/DockDesk-$VERSION.dmg"
[ -d "$APP" ] || { echo "missing $APP; run scripts/build-app.sh first" >&2; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DockDesk $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "built $DMG"
shasum -a 256 "$DMG"
