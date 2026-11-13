#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=Terminess
VERSION=$(cat VERSION)
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
BUILD=$(git rev-list --count HEAD)
echo "$NAME $VERSION ($BUILD)"

swift test -q
xcodegen generate -q

OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT" dist
cat > "$OUT/UploadOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>${TEAM_ID:?set TEAM_ID to your Apple Developer team ID}</string>
	<key>signingStyle</key><string>automatic</string>
	<key>destination</key><string>upload</string>
</dict>
</plist>
PLIST

xcodebuild archive -project $NAME.xcodeproj -scheme $NAME -configuration Release \
  -archivePath "$OUT/$NAME.xcarchive" -destination "generic/platform=macOS" \
  -derivedDataPath build/dd \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates -quiet
xcodebuild -exportArchive -archivePath "$OUT/$NAME.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/UploadOptions.plist" -allowProvisioningUpdates

echo "Sent to Apple; waiting for notarisation..."
until xcodebuild -exportNotarizedApp -archivePath "$OUT/$NAME.xcarchive" -exportPath "$OUT/notarized" > "$OUT/notary.log" 2>&1; do
  sleep 60
done
APP="$OUT/notarized/$NAME.app"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"

DMG="dist/$NAME-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
rm -rf dist/$NAME.app && ditto "$APP" dist/$NAME.app

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
find "$OUT" build/dd -name "$NAME.app" -maxdepth 8 -type d 2>/dev/null | while read -r a; do $LSREGISTER -u "$a" 2>/dev/null || true; done
rm -rf "$OUT/export" "$OUT/notarized"

if [[ "${1:-}" == "--install" ]]; then
  if pgrep -xq "$NAME"; then
    echo "$NAME is running; quit it, then: ditto dist/$NAME.app /Applications/$NAME.app" >&2
  else
    rm -rf "/Applications/$NAME.app"
    ditto "dist/$NAME.app" "/Applications/$NAME.app"
    echo "Installed /Applications/$NAME.app"
  fi
fi
echo "Done: $DMG ($(shasum -a 256 "$DMG" | cut -c1-64))"
