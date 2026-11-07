#!/bin/bash
# Removes WindowBar, its autostart, its permission and its signing keychain.
# Quitting first gives shortened windows their height back.
set -uo pipefail

LABEL=local.windowbar
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
for _ in $(seq 50); do pgrep -x WindowBar >/dev/null || break; sleep 0.1; done

tccutil reset Accessibility "$LABEL" >/dev/null 2>&1
rm -rf "$HOME/Applications/WindowBar.app" "$HOME/Library/LaunchAgents/$LABEL.plist" \
  "$HOME/Library/Logs/WindowBar" "$HOME/Library/Application Support/WindowBar"
security delete-keychain "$HOME/Library/Keychains/windowbar-signing.keychain-db" 2>/dev/null
security delete-generic-password -s windowbar-signing-keychain >/dev/null 2>&1
echo "WindowBar removed"
