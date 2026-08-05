#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/build/Flamm.app"
contents_dir="$app_dir/Contents"
binary_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
version="${FLAMM_VERSION:-1.0.0}"
build_number="${FLAMM_BUILD_NUMBER:-1}"

cd "$project_dir"
swift build --configuration "$configuration"

binary_path="$(swift build --configuration "$configuration" --show-bin-path)/Flamm"
/bin/rm -rf "$app_dir"
mkdir -p "$binary_dir" "$resources_dir"
cp "$binary_path" "$binary_dir/Flamm"
"$project_dir/Scripts/build-icon.sh" "$resources_dir/Flamm.icns"

/usr/libexec/PlistBuddy -c 'Clear dict' "$contents_dir/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleDevelopmentRegion string en' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Flamm' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Flamm' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Flamm' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.hegar.flamm' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Flamm' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSApplicationCategoryType string public.app-category.utilities' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string NSApplication' "$contents_dir/Info.plist"

codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
