#!/bin/bash
# Build TalkAI as a proper macOS .app bundle
set -e

APP_NAME="TalkAI"
BUNDLE_ID="com.talkai.TalkAI"
BUILD_DIR=".build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."
swift build -c debug

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary only if changed (preserves Accessibility permission)
if ! cmp -s .build/debug/TalkAI "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null; then
    cp .build/debug/TalkAI "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    NEEDS_SIGN=true
else
    NEEDS_SIGN=false
fi

# Create Info.plist with bundle identifier
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.talkai.TalkAI</string>
    <key>CFBundleName</key>
    <string>TalkAI</string>
    <key>CFBundleDisplayName</key>
    <string>TalkAI</string>
    <key>CFBundleExecutable</key>
    <string>TalkAI</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
</dict>
</plist>
PLIST

# Sign with entitlements (ad-hoc)
codesign --force --sign - --entitlements TalkAI/TalkAI.entitlements "$APP_BUNDLE"

echo ""
echo "Built: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
