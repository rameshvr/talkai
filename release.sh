#!/bin/bash
# Build TalkAI release DMG
set -e

VERSION="${1:?Usage: ./release.sh <version> (e.g., ./release.sh 1.0.0)}"

APP_NAME="TalkAI"
BUNDLE_ID="com.talkai.TalkAI"
BUILD_DIR=".build/release-app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="TalkAI-v${VERSION}-mac.dmg"
DMG_DIR=".build/dmg"

echo "==> Building $APP_NAME v$VERSION (release)..."
swift build -c release

echo "==> Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy release binary
cp .build/release/TalkAI "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Create Info.plist with version
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>TalkAI needs microphone access to capture your speech for transcription.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>TalkAI uses on-device speech recognition to transcribe your speech.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> Signing app bundle (ad-hoc)..."
codesign --force --deep --sign - --entitlements TalkAI/TalkAI.entitlements "$APP_BUNDLE"

echo "==> Creating DMG..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_BUNDLE" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

rm -f "$DMG_NAME"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_NAME"

rm -rf "$DMG_DIR"

echo ""
echo "==> Done!"
echo "    DMG: $DMG_NAME"
echo "    SHA256: $(shasum -a 256 "$DMG_NAME" | awk '{print $1}')"
echo ""
echo "To create a GitHub release:"
echo "    git tag v$VERSION && git push origin v$VERSION"
echo "    gh release create v$VERSION $DMG_NAME --title \"v$VERSION\" --generate-notes"
