#!/bin/zsh
set -euo pipefail

test_dir="${0:A:h}"
project_dir="${test_dir:h:h}"
scratch_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agentguard-ac-idle-sleep.XXXXXX")"
trap '/bin/rm -rf -- "$scratch_dir"' EXIT

/usr/bin/swiftc -swift-version 6 -module-cache-path "$scratch_dir/cache" \
    "$project_dir/Sources/AgentGuard/ACIdleSleepController.swift" "$test_dir/main.swift" \
    -o "$scratch_dir/ACIdleSleepRegression"
/usr/bin/codesign --force --sign - --timestamp=none "$scratch_dir/ACIdleSleepRegression"
"$scratch_dir/ACIdleSleepRegression"
