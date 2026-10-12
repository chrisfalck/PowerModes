#!/bin/sh
# Install the menu bar app for the current user and start it at login. Needs no sudo.
set -eu
cd "$(dirname "$0")/.."
[ "$(id -u)" != 0 ] || { echo "Run this one without sudo." >&2; exit 1; }
LABEL=io.github.chrisfalck.power-modes
APP="$HOME/Applications/Power Modes.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
./scripts/build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
/usr/bin/pkill -x PowerModes 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
cp -R "build/Power Modes.app" "$APP"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/PowerModes</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed $APP; it starts at login (launch agent $LABEL)."
