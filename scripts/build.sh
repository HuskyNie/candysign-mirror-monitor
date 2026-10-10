#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Mirror Monitor.app"
mkdir -p "$APP/Contents/MacOS" build/module-cache
swiftc -swift-version 5 -O -module-cache-path "$PWD/build/module-cache" \
  -target "$(uname -m)-apple-macosx13.0" \
  Sources/Metrics.swift Sources/main.swift -o "$APP/Contents/MacOS/MirrorMonitor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MirrorMonitor</string>
<key>CFBundleIdentifier</key><string>com.husky.mirror-monitor</string>
<key>CFBundleName</key><string>Mirror Monitor</string>
<key>CFBundleDisplayName</key><string>小电拼</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>连接你的小电拼，显示各 USB 端口的实时电压、电流和功率。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
