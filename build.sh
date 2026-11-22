#!/bin/bash
# Builds a release binary and wraps it in AIUsage.app (menu-bar only, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/AIUsage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/AIUsage" "$APP/Contents/MacOS/AIUsage"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AIUsage</string>
  <key>CFBundleDisplayName</key><string>AI Usage</string>
  <key>CFBundleIdentifier</key><string>local.aiusage.menubar</string>
  <key>CFBundleExecutable</key><string>AIUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "${1:-}" = "install" ]; then
  mkdir -p ~/Applications
  pkill -x AIUsage 2>/dev/null || true
  rm -rf ~/Applications/AIUsage.app
  cp -R "$APP" ~/Applications/AIUsage.app
  open ~/Applications/AIUsage.app
  echo "Installed to ~/Applications/AIUsage.app"
fi
