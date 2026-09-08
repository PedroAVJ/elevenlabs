#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
desktop_icon_source="$root/assets/elevenlabs-icon.svg"
desktop_icon="$root/assets/elevenlabs-icon.png"
ios_icon_source="$root/assets/dictation-button-ios-icon.svg"
ios_icon="$root/assets/elevenlabs-ios-icon.png"
icon_dir="$root/apps/ElevenLabs/ios/ElevenLabs/Assets.xcassets/AppIcon.appiconset"

for source_icon in "$desktop_icon_source" "$ios_icon_source"; do
    if [ ! -f "$source_icon" ]; then
        echo "error: canonical Dictation Button icon is missing: $source_icon" >&2
        exit 1
    fi
done
if [ ! -d "$icon_dir" ]; then
    echo "error: native app icon catalog is missing: $icon_dir" >&2
    exit 1
fi

/usr/bin/sips -s format png -z 1024 1024 "$desktop_icon_source" --out "$desktop_icon" >/dev/null
mkdir -p "$root/.eas-local-build"
icon_build_dir=$(mktemp -d "$root/.eas-local-build/icons.XXXXXX")
trap 'find "$icon_build_dir" -type f -delete; rmdir "$icon_build_dir"' EXIT
/usr/bin/sips -s format jpeg -z 1024 1024 "$ios_icon_source" --out "$icon_build_dir/dictation-button-ios.jpg" >/dev/null
/usr/bin/sips -s format png "$icon_build_dir/dictation-button-ios.jpg" --out "$ios_icon" >/dev/null

resize() {
    source_icon=$1
    name=$2
    size=$3
    /usr/bin/sips -z "$size" "$size" "$source_icon" --out "$icon_dir/$name" >/dev/null
}

/usr/bin/install -m 644 "$desktop_icon" "$icon_dir/AppIcon.png"
/usr/bin/install -m 644 "$ios_icon" "$icon_dir/AppIcon-iOS.png"
/usr/bin/install -m 644 "$desktop_icon" "$root/skills/elevenlabs/assets/elevenlabs-icon.png"
resize "$desktop_icon" AppIcon-16.png 16
resize "$desktop_icon" AppIcon-32.png 32
resize "$desktop_icon" AppIcon-64.png 64
resize "$desktop_icon" AppIcon-128.png 128
resize "$desktop_icon" AppIcon-256.png 256
resize "$desktop_icon" AppIcon-512.png 512
resize "$ios_icon" AppIcon-20@2x.png 40
resize "$ios_icon" AppIcon-20@3x.png 60
resize "$ios_icon" AppIcon-29@2x.png 58
resize "$ios_icon" AppIcon-29@3x.png 87
resize "$ios_icon" AppIcon-40@2x.png 80
resize "$ios_icon" AppIcon-40@3x.png 120
resize "$ios_icon" AppIcon-60@2x.png 120
resize "$ios_icon" AppIcon-60@3x.png 180

echo "Synchronized original Dictation Button artwork for the plugin, macOS app, and iOS app"
