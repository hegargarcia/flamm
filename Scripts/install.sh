#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
source_app="$project_dir/build/Flamm.app"
install_dir="$HOME/Applications"
installed_app="$install_dir/Flamm.app"

"$project_dir/Scripts/build-app.sh" release
mkdir -p "$install_dir"
/usr/bin/ditto "$source_app" "$installed_app"
/usr/bin/open "$installed_app"

print "Installed Flamm at $installed_app"
