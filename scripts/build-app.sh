#!/bin/bash
set -euo pipefail

APP_NAME="AI Usage Meter"
BUNDLE_ID="com.aiusagemeter"
VERSION="${1:-1.0.0}"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Multi-turn Inc. (8V3Z27Z6RY)}"
TEAM_ID="${TEAM_ID:-8V3Z27Z6RY}"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
NOTARIZE="${NOTARIZE:-}"
RESEND_API_KEY="${RESEND_API_KEY:-}"
FEEDBACK_EMAIL="${FEEDBACK_EMAIL:-}"
DONATION_URL="${DONATION_URL:-}"

echo "🔨 Building AI Usage Meter v$VERSION..."

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Resources/Scripts"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp "$BUILD_DIR/AIUsageMeter" "$APP_BUNDLE/Contents/MacOS/"

if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    cp -R "$BUILD_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
    if ! otool -l "$APP_BUNDLE/Contents/MacOS/AIUsageMeter" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/AIUsageMeter"
    fi
fi

if [ -f "Sources/AIUsageMeter/Resources/Scripts/updater.sh" ]; then
    cp "Sources/AIUsageMeter/Resources/Scripts/updater.sh" "$APP_BUNDLE/Contents/Resources/Scripts/"
    chmod +x "$APP_BUNDLE/Contents/Resources/Scripts/updater.sh"
fi

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "✅ App icon (.icns) copied"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>AIUsageMeter</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>SUFeedURL</key>
    <string>https://github.com/multi-turn-inc/ai-usage-meter/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>OFZWN3IMKCwZ7nWqf8hreBnNLdPLe0LxleGaTFbXFmo=</string>
    <key>ResendAPIKey</key>
    <string>$RESEND_API_KEY</string>
    <key>FeedbackEmail</key>
    <string>$FEEDBACK_EMAIL</string>
    <key>DonationURL</key>
    <string>$DONATION_URL</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "✅ App bundle created: $APP_BUNDLE"

echo "🔐 Signing app with Developer ID..."
codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"
echo "✅ App signed successfully"

DMG_NAME="AIUsageMeter-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_RW="$BUILD_DIR/rw.dmg"

echo "📦 Creating DMG with custom layout..."
rm -f "$DMG_PATH" "$DMG_RW"

DMG_TEMP="$BUILD_DIR/dmg-temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP/.background"
cp -R "$APP_BUNDLE" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

# Copy background image if present
if [ -f "scripts/dmg-assets/background.png" ]; then
    cp "scripts/dmg-assets/background.png" "$DMG_TEMP/.background/background.png"
fi

# Create writable DMG
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TEMP" -ov -format UDRW -fs HFS+ "$DMG_RW"

# Mount and customize
MOUNT_DIR="/Volumes/$APP_NAME"
hdiutil detach "$MOUNT_DIR" 2>/dev/null || true
hdiutil attach "$DMG_RW" -mountpoint "$MOUNT_DIR" -nobrowse
sleep 3

# Apply custom view via AppleScript (with extended timeout)
osascript <<APPLESCRIPT
with timeout of 120 seconds
    tell application "Finder"
        tell disk "$APP_NAME"
            open
            delay 2
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {400, 100, 940, 480}
            set theViewOptions to the icon view options of container window
            set arrangement of theViewOptions to not arranged
            set icon size of theViewOptions to 110
            set text size of theViewOptions to 12
            try
                set background picture of theViewOptions to file ".background:background.png"
            end try
            set position of item "$APP_NAME.app" of container window to {145, 210}
            set position of item "Applications" of container window to {400, 210}
            update without registering applications
            delay 3
            close
        end tell
    end tell
end timeout
APPLESCRIPT

sync
sleep 1
hdiutil detach "$MOUNT_DIR" 2>/dev/null || hdiutil detach "$MOUNT_DIR" -force

# Convert to compressed read-only
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_RW"
rm -rf "$DMG_TEMP"

echo "🔐 Signing DMG..."
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
echo "✅ DMG signed successfully"

if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" || ( -n "$APPLE_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" ) ]]; then
    if [[ -z "$APPLE_ID" || -z "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
        echo "❌ NOTARIZE requested but missing credentials."
        echo "   Set env vars:"
        echo "   - APPLE_ID"
        echo "   - APPLE_APP_SPECIFIC_PASSWORD (App-Specific Password)"
        echo "   - TEAM_ID (optional, default: $TEAM_ID)"
        exit 1
    fi

    echo "🧾 Notarizing DMG with Apple Notary Service..."
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait

    echo "📎 Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    echo "✅ Notarization completed"
else
    echo "⚠️  Not notarized."
    echo "   To avoid the Gatekeeper warning, notarize the DMG. Re-run with:"
    echo "   - NOTARIZE=1"
    echo "   - APPLE_ID"
    echo "   - APPLE_APP_SPECIFIC_PASSWORD (App-Specific Password)"
    echo "   - TEAM_ID (optional)"
fi

echo "✅ DMG created: $DMG_PATH"
echo ""
echo "📋 Release files:"
ls -lh "$BUILD_DIR"/*.dmg 2>/dev/null || true

echo ""
echo "🔎 Verification (recommended):"
echo "   spctl -a -vv \"$APP_BUNDLE\""
echo "   spctl -a -vv --type install \"$DMG_PATH\""
