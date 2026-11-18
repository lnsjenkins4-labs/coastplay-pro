#!/bin/bash
# Builds "CoastPlay Host.app" for local testing only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
swift build -c release --product rgp-mirror-host
APP="$HERE/.build/CoastPlay Host.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/rgp-mirror-host "$APP/Contents/MacOS/CoastPlayHost"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.cardinalecosystem.coastplayhost</string>
  <key>CFBundleName</key><string>CoastPlay Host</string>
  <key>CFBundleDisplayName</key><string>CoastPlay Host</string>
  <key>CFBundleExecutable</key><string>CoastPlayHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Lets your paired phone find and connect to this Mac.</string>
  <key>NSBonjourServices</key><array><string>_rgpmirror._tcp</string></array>
  <key>NSScreenCaptureUsageDescription</key><string>Shows this Mac's screen on your paired phone so you can play from it.</string>
</dict></plist>
P
# Sign with the developer certificate when there is one, so macOS keeps the screen-recording
# and control permissions between rebuilds. Ad-hoc signing makes macOS ask again every time.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1
else codesign --force --sign - "$APP" >/dev/null 2>&1; fi
echo "$APP"
# Optional: ./make-host-app.sh --install also copies it into /Applications so it shows in
# Launchpad and Spotlight. Quit the running copy first.
if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/CoastPlay Host.app" && cp -R "$APP" "/Applications/CoastPlay Host.app" && echo "/Applications/CoastPlay Host.app"
fi
