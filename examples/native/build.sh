#!/bin/bash
# Build the native SwiftUI showcase into a simulator .app (no Xcode project, no
# signing — the simulator runs unsigned apps). Install + launch on the booted sim.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="WandShowcaseNative"
BUNDLE="com.wand.showcase.native"
OUT="$DIR/build/$APP.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

rm -rf "$DIR/build"
mkdir -p "$OUT"

echo "Compiling..."
xcrun -sdk iphonesimulator swiftc \
  -target arm64-apple-ios17.0-simulator \
  -sdk "$SDK" \
  -framework SwiftUI -framework UIKit \
  -parse-as-library \
  -emit-executable \
  -o "$OUT/$APP" \
  "$DIR/Showcase.swift"

cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE</string>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>Wand Native</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
PLIST

echo "Installing on booted simulator..."
xcrun simctl install booted "$OUT"
xcrun simctl launch booted "$BUNDLE"
echo "Done: $OUT"
