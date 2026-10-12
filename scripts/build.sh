#!/bin/sh
# Build "Power Modes.app" and the root helper into build/. Changes nothing outside this folder.
set -eu
cd "$(dirname "$0")/.."
APP="build/Power Modes.app"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PowerModes "$APP/Contents/MacOS/PowerModes"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Power Modes</string>
<key>CFBundleDisplayName</key><string>Power Modes</string>
<key>CFBundleIdentifier</key><string>io.github.chrisfalck.power-modes</string>
<key>CFBundleExecutable</key><string>PowerModes</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
xcrun clang -std=c11 -fobjc-arc -O2 -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics \
    Helper/power-modes-helper.m -o build/io.github.chrisfalck.powermodes.helper
echo "Built $APP and build/io.github.chrisfalck.powermodes.helper"
