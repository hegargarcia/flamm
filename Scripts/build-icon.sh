#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
source_icon="$project_dir/assets/icon.svg"
output_icon="${1:-$project_dir/build/Flamm.icns}"
work_dir="$(mktemp -d)"
iconset_dir="$work_dir/Flamm.iconset"

trap '/bin/rm -rf "$work_dir"' EXIT

mkdir -p "$iconset_dir" "${output_icon:h}"
/usr/bin/sips -s format png "$source_icon" --out "$work_dir/source.png" >/dev/null

function render_icon() {
    local pixels="$1"
    local filename="$2"
    /usr/bin/sips -z "$pixels" "$pixels" "$work_dir/source.png" \
        --out "$iconset_dir/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$iconset_dir" -o "$output_icon"
print "$output_icon"
