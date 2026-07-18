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
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
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
