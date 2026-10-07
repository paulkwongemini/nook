#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Optional asset-authoring step; normal builds use the checked-in PNG/ICNS files.
command -v rsvg-convert >/dev/null
command -v iconutil >/dev/null
icon_work="$(mktemp -d)"
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" Resources/AppIcon.svg -o "$iconset/icon_${size}x${size}.png"
  retina=$((size * 2))
  rsvg-convert -w "$retina" -h "$retina" Resources/AppIcon.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns

for service in chat gmail drive calendar; do
  rsvg-convert -w 192 -h 192 "Native/Resources/ServiceIcons/$service.svg" \
    -o "Native/Resources/ServiceIcons/$service.png"
done
printf 'Rendered Nook app and service icons.\n'
