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
# Compile the lifecycle harness with the app sources, excluding its GUI entry point.
# This keeps tests runnable with the command-line tools alone (no XCTest/Xcode).
lifecycle_sources=()
for source in "$project_dir"/Sources/Flamm/*.swift; do
  if [[ "${source:t}" != "FlammApp.swift" ]]; then
    lifecycle_sources+=("$source")
  fi
done
swiftc "${lifecycle_sources[@]}" \
  "$project_dir/Tests/FlammTests/LifecycleTests.swift" \
  "$project_dir/Tests/FlammTests/TransportTests.swift" \
  -o "$test_dir/flamm-lifecycle-test"
"$test_dir/flamm-lifecycle-test"

swiftc "$project_dir/Sources/Flamm/AppUpdate.swift" \
  "$project_dir/Tests/FlammTests/UpdateTests.swift" \
  -o "$test_dir/flamm-update-test"
"$test_dir/flamm-update-test"

swift build --package-path "$project_dir"
