#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
source_app="$project_dir/build/Flamm.app"
artifacts_dir="$project_dir/Artifacts"
staging_dir="$(mktemp -d)"

trap '/bin/rm -rf "$staging_dir"' EXIT

"$project_dir/Scripts/build-app.sh" release

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
architecture="$(/usr/bin/uname -m)"
disk_image="$artifacts_dir/Flamm-v${version}-macOS-${architecture}.dmg"
checksum="$disk_image.sha256"

mkdir -p "$artifacts_dir"
/usr/bin/ditto "$source_app" "$staging_dir/Flamm.app"
/bin/ln -s /Applications "$staging_dir/Applications"
/bin/rm -f "$disk_image" "$checksum"

/usr/bin/hdiutil create \
    -volname Flamm \
    -srcfolder "$staging_dir" \
    -format UDZO \
    -ov \
    "$disk_image"

(
    cd "$artifacts_dir"
    /usr/bin/shasum -a 256 "${disk_image:t}" > "${checksum:t}"
)

print "Created $disk_image"
print "Created $checksum"
