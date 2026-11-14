#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product TermApp
swift build -c release --product terminessd
APP=dist/terminal-dev.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TermApp "$APP/Contents/MacOS/TermApp"
cp .build/release/terminessd "$APP/Contents/MacOS/terminessd"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/bin"
install -m 755 scripts/pair "$APP/Contents/Resources/bin/pair"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>terminal dev</string>
  <key>CFBundleDisplayName</key><string>terminal dev</string>
  <key>CFBundleIdentifier</key><string>local.terminal.dev</string>
  <key>CFBundleExecutable</key><string>TermApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSLocalNetworkUsageDescription</key><string>Terminess listens on your network briefly while you pair your iPhone.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Shells and agents in Terminess read and write files on your Desktop when you ask them to.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Shells and agents in Terminess read and write files in Documents when you ask them to.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Shells and agents in Terminess read files in Downloads, such as screenshots you drop in.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Shells and agents in Terminess read and write files on external drives when you ask them to.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Shells and agents in Terminess read and write files on network drives when you ask them to.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
