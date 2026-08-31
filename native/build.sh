#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
APP="$BUILD/OCR2MD Sync Status.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
rm -rf "$APP"
mkdir -p "$MACOS"
xcrun clang -fobjc-arc -framework Cocoa "$ROOT/native/main.m" "$ROOT/native/SyncGroupManager.m" -o "$MACOS/OCR2MDSyncStatus"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>OCR2MDSyncStatus</string>
  <key>CFBundleIdentifier</key><string>com.ocr2md.syncstatus</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>OCR2MD Sync Status</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist"
echo "$APP"
