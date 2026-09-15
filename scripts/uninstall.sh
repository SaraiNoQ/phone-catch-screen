#!/usr/bin/env bash
#
# Stops the LaunchAgent and removes the installed bundle. Config and logs are
# deliberately left in place so a reinstall keeps your settings.

set -euo pipefail

APP="$HOME/Applications/PHONE-CATCH-SCREEN.app"
BINARY="$APP/Contents/MacOS/screenbeam"

if [[ -x "$BINARY" ]]; then
    "$BINARY" uninstall
else
    # Fall back to launchctl directly if the bundle is already gone.
    /bin/launchctl bootout "gui/$(id -u)/com.sarainoq.screenbeam" 2>/dev/null || true
    /bin/rm -f "$HOME/Library/LaunchAgents/com.sarainoq.screenbeam.plist"
    /bin/rm -rf "$APP"
    echo "已移除应用与 LaunchAgent。"
fi
