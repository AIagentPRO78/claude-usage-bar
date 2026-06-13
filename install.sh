#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/ClaudeUsageBar.app"
cp -R ClaudeUsageBar.app "$DEST/"

# Start at login (no Dock icon; LSUIElement app).
PLIST="$HOME/Library/LaunchAgents/com.ellerywee.claudeusagebar.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ellerywee.claudeusagebar</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PL

# Stop any running copies, then (re)load the agent. RunAtLoad starts exactly one
# instance — do NOT also `open` the app, or you'd get two menu-bar icons.
killall ClaudeUsageBar 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed to $DEST/ClaudeUsageBar.app and set to launch at login."
