#!/bin/bash
# Builds PingBar.app into ./build
set -euo pipefail

cd "$(dirname "$0")"
APP="build/PingBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>PingBar</string>
    <key>CFBundleDisplayName</key>     <string>PingBar</string>
    <key>CFBundleExecutable</key>      <string>PingBar</string>
    <key>CFBundleIdentifier</key>      <string>com.github.cameralis.pingbar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

swiftc -O -target arm64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/PingBar" \
    Sources/main.swift

codesign --force --sign - "$APP"

echo "Built $PWD/$APP"
