#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="/Applications/Music Wallpaper.app"
if [ -e "$app" ]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    if [ "$existing_id" != "local.musicwallpaper.prototype" ]; then
        printf 'Ya existe otra app con ese nombre: %s\n' "$app" >&2
        exit 1
    fi
fi
bash scripts/build.sh
ditto 'build/Music Wallpaper.app' "$app"
"$app/Contents/MacOS/MusicWallpaper" --enable-login --configure-only
printf 'App instalada en %s\n' "$app"
