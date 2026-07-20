#!/bin/zsh
# Builds Muro in release mode and assembles a proper Muro.app bundle.
# Usage: ./build-app.sh [--install] [--dmg]
#   --install : also copy the bundle to /Applications (replacing any old one)
#   --dmg     : also build dist/Muro-<version>.dmg (drag-to-Applications layout)
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/dist/Muro.app"

echo "==> swift build -c release"
swift build -c release --package-path "$DIR"

echo "==> assembling $APP"
rm -rf "$DIR/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$DIR/.build/release/muro-app" "$APP/Contents/MacOS/Muro"

# App icon (concept A "Moonbeam"), if present — source + generator in Icon/.
if [[ -f "$DIR/Icon/AppIcon.icns" ]]; then
    cp "$DIR/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Bundled wallpaper: "Snowfall in Forest" full 4K master + thumb, so a fresh
# install always has one wallpaper playing in the hero (owner decision — 4K
# over DMG size). Sourced from the local library; the id must match
# BundledWallpaper.id in Sources/MuroApp/BundledWallpaper.swift.
BUNDLED_ID="c0b0484f-80b9-40f3-bf02-03cd0886ba82"
# Overridable, because tying the build to the developer's personal library
# means the DMG cannot be built whenever that library is wiped or partial —
# e.g. right after a fresh-install test. Point MURO_LIB at any folder holding
# Masters/<id>.mov + Thumbnails/<id>.jpg.
MURO_LIB="${MURO_LIB:-$HOME/Library/Application Support/Muro}"
if [[ -f "$MURO_LIB/Masters/$BUNDLED_ID.mov" && -f "$MURO_LIB/Thumbnails/$BUNDLED_ID.jpg" ]]; then
    cp "$MURO_LIB/Masters/$BUNDLED_ID.mov"    "$APP/Contents/Resources/BundledWallpaper.mov"
    cp "$MURO_LIB/Thumbnails/$BUNDLED_ID.jpg" "$APP/Contents/Resources/BundledWallpaper.jpg"
else
    echo "ERROR: bundled wallpaper $BUNDLED_ID not found in $MURO_LIB" >&2
    echo "       (Snowfall in Forest must be in the local library — a DMG without" >&2
    echo "       it ships a blank hero on fresh installs)" >&2
    exit 1
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Muro</string>
    <key>CFBundleDisplayName</key>     <string>Muro</string>
    <key>CFBundleExecutable</key>      <string>Muro</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIconName</key>        <string>AppIcon</string>
    <key>CFBundleIdentifier</key>      <string>com.mrrockysl.muro</string>
    <key>CFBundleVersion</key>         <string>4</string>
    <key>CFBundleShortVersionString</key> <string>1.1</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.entertainment</string>
    <key>NSHumanReadableCopyright</key> <string>Designed &amp; developed by MrRockySL</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

for arg in "$@"; do
    case "$arg" in
    --install)
        echo "==> installing to /Applications"
        rm -rf /Applications/Muro.app
        cp -R "$APP" /Applications/Muro.app
        echo "==> installed: /Applications/Muro.app"
        ;;
    --dmg)
        VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
        DMG="$DIR/dist/Muro-$VERSION.dmg"
        STAGING="$DIR/dist/dmg-staging"
        echo "==> building $DMG"
        rm -rf "$STAGING" "$DMG"
        mkdir -p "$STAGING"
        cp -R "$APP" "$STAGING/Muro.app"
        ln -s /Applications "$STAGING/Applications"
        hdiutil create -volname "Muro" -srcfolder "$STAGING" -format UDZO -quiet "$DMG"
        rm -rf "$STAGING"
        echo "==> dmg: $DMG"
        ;;
    esac
done
if [[ $# -eq 0 ]]; then
    echo "==> done: $APP  (--install copies to /Applications, --dmg builds the disk image)"
fi
