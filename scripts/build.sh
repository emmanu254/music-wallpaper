#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/Music Wallpaper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -parse-as-library -O Sources/MusicWallpaper.swift Sources/DesktopSpaces.swift -o "$app/Contents/MacOS/MusicWallpaper" -framework AppKit
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MusicWallpaper</string>
<key>CFBundleIdentifier</key><string>local.musicwallpaper.prototype</string>
<key>CFBundleName</key><string>Music Wallpaper</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Consulta la canción actual y su portada en Música o Spotify para actualizar el fondo de pantalla.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf 'Aplicación creada: %s\n' "$app"
