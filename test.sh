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
# Build before executing so macOS CI does not launch an executable carrying a
# toolchain-generated debug/entitlement signature before it can be normalized.
# This ad-hoc identity is ONLY for the disposable self-test binary, never the app
# bundle, Sparkle framework, or any release artifact.
swift build --scratch-path "$scratch_dir" --product AgentGuardSelfTest
binary_dir="$(swift build --scratch-path "$scratch_dir" --show-bin-path)"
self_test="$binary_dir/AgentGuardSelfTest"
/usr/bin/codesign --force --sign - --timestamp=none "$self_test"
/usr/bin/codesign --verify --strict --verbose=2 "$self_test"
"$self_test"

"$project_dir/Tests/SecureInputRegression/run.sh"

"$project_dir/Tests/DisplayRecoveryRegression/run.sh"

"$project_dir/Tests/AuthenticationInputScopeRegression/run.sh"

"$project_dir/Tests/AuthenticationLifecycleRegression/run.sh"

"$project_dir/Tests/UpdateInstallGateRegression/run.sh"

python3 "$project_dir/Tests/SparkleReleaseRegression/run.py"

"$project_dir/Tests/SparkleAdapterRegression/run.sh"
