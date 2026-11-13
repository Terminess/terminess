#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
swift scripts/make-icon.swift assets/icon-1024.png 1024 >/dev/null
for n in 16 32 128 256 512; do
  sips -z $n $n assets/icon-1024.png --out "$SET/icon_${n}x${n}.png" >/dev/null
  d=$((n * 2))
  sips -z $d $d assets/icon-1024.png --out "$SET/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "Built assets/AppIcon.icns"
