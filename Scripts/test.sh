#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc \
  "$project_dir/Sources/Flamm/ForwardedPort.swift" \
  "$project_dir/Sources/Flamm/LocalReachability.swift" \
  "$project_dir/Sources/Flamm/SSHConfig.swift" \
  "$project_dir/Tests/FlammTests/SelfTest.swift" \
  -o "$test_dir/flamm-self-test"

"$test_dir/flamm-self-test"
swift build --package-path "$project_dir"
