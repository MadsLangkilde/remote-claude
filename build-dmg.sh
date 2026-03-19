#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# build-dmg.sh — Build Remote Claude DMG installer
# ─────────────────────────────────────────────────────────────────
set -e

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"

VERSION="1.0"
APP_NAME="Remote Claude"
DMG_NAME="RemoteClaude-${VERSION}"
VOLUME_NAME="Remote Claude"
DMG_FINAL="${PROJECT_DIR}/${DMG_NAME}.dmg"

BUILD_DIR="$(mktemp -d)"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

echo ""
echo "  ┌────────────────────────────────────────┐"
echo "  │  Building Remote Claude ${VERSION} DMG        │"
echo "  └────────────────────────────────────────┘"
echo ""

# ─── 1. Compile Swift binary ────────────────────────────────────
echo "  [1/5] Compiling macOS app..."
swiftc -O \
  -o macos-app/RemoteClaude \
  macos-app/RemoteClaude.swift \
  -framework Cocoa 2>&1 | sed 's/^/    /'

# ─── 2. Create .icns icon ──────────────────────────────────────
echo "  [2/5] Creating app icon..."
ICONSET="${BUILD_DIR}/RemoteClaude.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size public/icon-512.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
done
for size in 16 32 128 256; do
  double=$((size * 2))
  sips -z $double $double public/icon-512.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
done
iconutil -c icns -o macos-app/RemoteClaude.icns "$ICONSET"

# ─── 3. Assemble .app bundle ───────────────────────────────────
echo "  [3/5] Assembling app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp macos-app/RemoteClaude "${APP_BUNDLE}/Contents/MacOS/"
cp macos-app/RemoteClaude.icns "${APP_BUNDLE}/Contents/Resources/"

# Bundle server files so the app is self-contained
SERVER_RES="${APP_BUNDLE}/Contents/Resources/server"
mkdir -p "$SERVER_RES/public"
cp server.js "$SERVER_RES/"
cp package.json "$SERVER_RES/"
cp package-lock.json "$SERVER_RES/"
cp remote-claude "$SERVER_RES/"
cp .gitignore "$SERVER_RES/" 2>/dev/null || true
cp CLAUDE.md "$SERVER_RES/" 2>/dev/null || true
cp -R public/ "$SERVER_RES/public/"

cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Remote Claude</string>
    <key>CFBundleDisplayName</key>
    <string>Remote Claude</string>
    <key>CFBundleIdentifier</key>
    <string>com.madsvejenlangkilde.remote-claude</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>RemoteClaude</string>
    <key>CFBundleIconFile</key>
    <string>RemoteClaude</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Mads Vejen Langkilde</string>
</dict>
</plist>
PLIST

# Ad-hoc code sign so macOS doesn't flag it as "damaged"
codesign --force --deep -s - "${APP_BUNDLE}"

# ─── 4. Stage DMG contents ─────────────────────────────────────
echo "  [4/5] Staging DMG contents..."
STAGE="${BUILD_DIR}/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Background image
mkdir -p "$STAGE/.background"
MAGICK=$(command -v magick || command -v /opt/homebrew/bin/magick || echo "")
if [ -n "$MAGICK" ]; then
  "$MAGICK" -size 660x600 'xc:srgb(255,255,255)' \
    -fill '#333333' -font 'Helvetica-Bold' -pointsize 24 -gravity North -annotate +0+30 'Remote Claude' \
    -fill '#888888' -font 'Helvetica' -pointsize 13 -gravity North -annotate +0+61 'Access Claude Code from your phone' \
    -fill '#cccccc' -font 'Helvetica' -pointsize 36 -gravity Center -annotate +0-80 '>' \
    -fill '#bbbbbb' -pointsize 12 -gravity Center -annotate +0-45 'drag to install' \
    -fill '#999999' -font 'Helvetica' -pointsize 10 -gravity SouthWest -annotate +15+12 'Made by Mads Vejen Langkilde' \
    -type TrueColor \
    "$STAGE/.background/background.png"
elif [ -f macos-app/dmg-background.png ]; then
  cp macos-app/dmg-background.png "$STAGE/.background/background.png"
fi

# Getting Started file
cat > "$STAGE/Getting Started.txt" << 'README'
═══════════════════════════════════════════
  Remote Claude — Getting Started
═══════════════════════════════════════════

  Access Claude Code from your phone,
  anywhere — with full voice control.


  INSTALL
  ───────
  Drag "Remote Claude" to Applications.
  Launch it — a mic icon appears in your
  menu bar. Click "Setup Guide..." to
  configure everything step by step.


  WHAT YOU CAN DO
  ───────────────
  · Start Claude Code sessions from your phone
  · Talk to Claude hands-free with voice
  · Approve file changes, review output
  · Sessions survive when your phone sleeps


  PREREQUISITES
  ─────────────
  · Node.js v18+     — nodejs.org
  · Claude Code      — npm i -g @anthropic-ai/claude-code
  · Tailscale (free) — tailscale.com
  · Gemini API key   — aistudio.google.com
                       (optional, for voice mode)

  The Setup Guide in the app walks you
  through all of these.


  PROJECT SERVER CODE
  ───────────────────
  The menu bar app manages a Node.js server
  that lives at ~/projects/remote-claude.

  Clone it there if you haven't already:

    git clone <repo> ~/projects/remote-claude
    cd ~/projects/remote-claude
    npm install


  MORE INFO
  ─────────
  See README.md in the project directory
  for architecture details, voice control
  documentation, and troubleshooting.

───────────────────────────────────────────
  By Mads Vejen Langkilde
───────────────────────────────────────────
README

# ─── 5. Create DMG ─────────────────────────────────────────────
echo "  [5/5] Creating DMG..."

# Remove previous DMG if it exists
rm -f "$DMG_FINAL"

# Detach any previous mount of this volume
hdiutil detach "/Volumes/${VOLUME_NAME}" 2>/dev/null || true

# Create writable DMG
DMG_TEMP="${BUILD_DIR}/${DMG_NAME}-temp.dmg"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDRW \
  -fs HFS+ \
  "$DMG_TEMP" >/dev/null

# Mount it
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP" | grep '/Volumes/' | head -1 | awk '{print $1}')

# Set Finder window properties via AppleScript
sleep 1
osascript << APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 80, 760, 680}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {155, 170}
        set position of item "Applications" of container window to {505, 170}
        set position of item "Getting Started.txt" of container window to {330, 370}
        close
        open
    end tell
end tell
APPLESCRIPT

# Let Finder flush .DS_Store
sleep 2

# Set volume icon
cp macos-app/RemoteClaude.icns "/Volumes/${VOLUME_NAME}/.VolumeIcon.icns"
SetFile -a C "/Volumes/${VOLUME_NAME}" 2>/dev/null || true

# Unmount
sync
hdiutil detach "$DEVICE" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_FINAL" >/dev/null

# Update the local installed copy from the DMG
echo ""
echo "  Updating ~/Applications..."
mkdir -p ~/Applications
DEVICE2=$(hdiutil attach -readonly -noautoopen "$DMG_FINAL" | grep '/Volumes/' | head -1 | awk '{print $1}')
rm -rf ~/Applications/Remote\ Claude.app
cp -R "/Volumes/${VOLUME_NAME}/${APP_NAME}.app" ~/Applications/
hdiutil detach "$DEVICE2" -quiet

# Clean up
rm -rf "$BUILD_DIR"

SIZE=$(du -h "$DMG_FINAL" | cut -f1)
echo ""
echo "  ┌────────────────────────────────────────┐"
echo "  │  Done!                                  │"
echo "  │                                         │"
echo "  │  ${DMG_FINAL##*/}"
printf "  │  %-40s│\n" "Size: ${SIZE}"
echo "  └────────────────────────────────────────┘"
echo ""
