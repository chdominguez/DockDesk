#!/bin/sh
# Package dist/TwinDesk.app into dist/TwinDesk-<version>.dmg (app plus an Applications shortcut).
# Usage: scripts/make-dmg.sh <version>     Run scripts/build-app.sh first.
set -e
cd "$(dirname "$0")/.."
VERSION="${1:?usage: make-dmg.sh <version>}"
APP=dist/TwinDesk.app
DMG="dist/TwinDesk-$VERSION.dmg"
[ -d "$APP" ] || { echo "missing $APP; run scripts/build-app.sh first" >&2; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "TwinDesk $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "built $DMG"
shasum -a 256 "$DMG"
