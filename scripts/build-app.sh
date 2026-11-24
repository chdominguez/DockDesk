#!/bin/sh
# Build DockDesk.app (release) into ./dist and sign it.
# Set SIGN_ID to a code-signing identity to keep the Screen Recording
# permission across rebuilds; the default ad-hoc signature changes every build.
# Set VERSION (e.g. 0.2.0) and BUILD to stamp the bundle; release builds do.
set -e
cd "$(dirname "$0")/.."

plist() { # $1 = bundle path, $2 = bundle id
cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleName</key><string>DockDesk</string>
  <key>CFBundleExecutable</key><string>DockDesk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.1.0}</string>
  <key>CFBundleVersion</key><string>${BUILD:-1}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
}

if [ "$1" = "--dev" ]; then
    # Rebuild only the app library; the launcher bundle is created once and then left alone.
    swift build --product DockDeskDev
    mkdir -p dist
    cp .build/debug/libDockDeskDev.dylib dist/libDockDeskDev.dylib
    APP="dist/DockDesk Dev.app"
    if [ ! -x "$APP/Contents/MacOS/DockDesk" ]; then
        mkdir -p "$APP/Contents/MacOS"
        clang -O1 -o "$APP/Contents/MacOS/DockDesk" scripts/dev-launcher.c
        plist "$APP" io.github.dockdesk.DockDesk.dev
        mkdir -p "$APP/Contents/Resources"; cp Resources/AppIcon.icns "$APP/Contents/Resources/"
        codesign --force --sign - "$APP"
        echo "created $APP (grant Screen Recording to it once)"
    fi
    echo "built dist/libDockDeskDev.dylib"
    exit 0
fi
swift build -c release --arch arm64 --product DockDesk
APP=dist/DockDesk.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --show-bin-path)/DockDesk" "$APP/Contents/MacOS/DockDesk"
plist "$APP" io.github.dockdesk.DockDesk
mkdir -p "$APP/Contents/Resources"; cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "built $APP"
