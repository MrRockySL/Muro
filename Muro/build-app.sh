#!/bin/zsh
# Builds Muro in release mode and assembles a proper Muro.app bundle.
# Usage: ./build-app.sh [--install] [--dmg]
#   --install : also copy the bundle to /Applications (replacing any old one)
#   --dmg     : also build dist/Muro-<version>.dmg (drag-to-Applications layout)
set -e

# The one place Muro's version is written. The app bundle, the wallpaper
# extension and the DMG name are all derived from these two lines, and the
# build fails below if the app and the extension ever disagree.
VERSION="4.0"
BUILD="7"

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/dist/Muro.app"

# Universal, so every Mac that can run macOS 14 gets a native slice rather
# than only Apple Silicon. Both slices are the same source compiled twice,
# which is why nothing else in the project has to know about Intel: every
# later change reaches both without a second thought. The wallpaper
# extension carries the same two architectures, set in its Xcode project.
echo "==> swift build -c release (universal: arm64 + x86_64)"
swift build -c release --package-path "$DIR" --arch arm64 --arch x86_64

echo "==> assembling $APP"
rm -rf "$DIR/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$DIR/.build/release/muro-app" "$APP/Contents/MacOS/Muro"

# macOS 26+ lock-screen renderer. Build it as a real ExtensionKit target so
# ExtensionFoundation installs the correct entry point and actor isolation.
# The private wallpaper framework is loaded only at runtime.
EXT="$APP/Contents/Extensions/MuroWallpaperExtension.appex"
echo "==> building macOS 26+ wallpaper extension"
EXT_DERIVED="$DIR/.build/muro-wallpaper-extension"
xcodebuild \
    -project "$DIR/MuroWallpaperExtension.xcodeproj" \
    -scheme MuroWallpaperExtension \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$EXT_DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    build
mkdir -p "$APP/Contents/Extensions"
cp -R "$EXT_DERIVED/Build/Products/Release/MuroWallpaperExtension.appex" "$EXT"

# App icon (concept A "Moonbeam"), if present — source + generator in Icon/.
if [[ -f "$DIR/Icon/AppIcon.icns" ]]; then
    cp "$DIR/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cp "$DIR/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

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

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleVersion</key>         <string>$BUILD</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.entertainment</string>
    <key>NSHumanReadableCopyright</key> <string>Designed &amp; developed by MrRockySL</string>
</dict>
</plist>
PLIST

# A mismatched app and appex is the kind of thing nobody notices until an
# install refuses to load the extension, so check it here rather than hope.
EXT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$EXT/Contents/Info.plist")
EXT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$EXT/Contents/Info.plist")
if [[ "$EXT_VERSION" != "$VERSION" || "$EXT_BUILD" != "$BUILD" ]]; then
    echo "ERROR: extension is $EXT_VERSION ($EXT_BUILD), app is $VERSION ($BUILD)" >&2
    exit 1
fi
echo "==> version $VERSION ($BUILD), app and extension agree"

echo "==> ad-hoc codesign"
codesign --force --sign - \
    --entitlements "$DIR/Sources/MuroWallpaperExtension/MuroWallpaperExtension.entitlements" \
    "$EXT"
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
