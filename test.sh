#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
scratch_dir="$(/usr/bin/mktemp -d /private/tmp/agentguard-tests.XXXXXX)"

cleanup() {
  if [[ "$scratch_dir" == /private/tmp/agentguard-tests.* && -d "$scratch_dir" ]]; then
    /bin/rm -rf "$scratch_dir"
  fi
}
trap cleanup EXIT

cd "$project_dir"
swift run --scratch-path "$scratch_dir" AgentGuardSelfTest

"$project_dir/Tests/SecureInputRegression/run.sh"

"$project_dir/Tests/DisplayRecoveryRegression/run.sh"

"$project_dir/Tests/AuthenticationInputScopeRegression/run.sh"

"$project_dir/Tests/AuthenticationLifecycleRegression/run.sh"
