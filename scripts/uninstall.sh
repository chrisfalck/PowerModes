#!/bin/sh
# Remove Power Modes. Run without sudo for the app, with sudo for the helper and sudoers rule.
set -eu
if [ "$(id -u)" = 0 ]; then
    rm -f /Library/PrivilegedHelperTools/io.github.chrisfalck.powermodes.helper /etc/sudoers.d/power-modes-helper
    echo "Removed the helper and its sudoers rule. Power modes stay as they are now."
else
    LABEL=io.github.chrisfalck.power-modes
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    /usr/bin/pkill -x PowerModes 2>/dev/null || true
    rm -rf "$HOME/Applications/Power Modes.app"
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
    echo "Removed the app and its launch agent. Run again with sudo to remove the helper."
fi
