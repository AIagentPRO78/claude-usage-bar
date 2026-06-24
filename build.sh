#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"
BIN="ClaudeUsageBar"
BUNDLE_ID="com.ellerywee.claudeusagebar"

# `./build.sh test` builds and runs the unit tests, then exits.
if [[ "${1:-}" == "test" ]]; then
    echo "Building tests..."
    swiftc -O -parse-as-library -o /tmp/cub-tests Tests.swift EnterpriseTests.swift EnterpriseCore.swift EnterpriseClient.swift UsageCore.swift
    echo "Running tests..."
    /tmp/cub-tests
    exit $?
fi

echo "Compiling..."
swiftc -O -o "$BIN" main.swift UsageCore.swift -framework Cocoa

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

# App icon (master art + .icns are committed under assets/; regenerate with ./make-icon.sh).
if [[ -f assets/AppIcon.icns ]]; then
    cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper/TCC treat it as a stable app identity.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built ./$APP"
