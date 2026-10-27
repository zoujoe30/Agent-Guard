#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
if (( $# < 1 )); then
  echo "usage: $0 /absolute/output/directory" >&2
  exit 2
fi

output_dir="$1"
if [[ "$output_dir" != /* ]]; then
  echo "output directory must be an absolute path" >&2
  exit 2
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/AppInfo.plist")"
archive_path="$output_dir/Agent Guard-$version.zip"
signing_identity="${AGENT_GUARD_SIGNING_IDENTITY:?Set AGENT_GUARD_SIGNING_IDENTITY to a stable code-signing identity}"
distribution_build="${AGENT_GUARD_DISTRIBUTION:-0}"
scratch_dir="$(/usr/bin/mktemp -d /private/tmp/agentguard-build.XXXXXX)"
temporary_app="$scratch_dir/Agent Guard.app"

cleanup() {
  if [[ "$scratch_dir" == /private/tmp/agentguard-build.* && -d "$scratch_dir" ]]; then
    /bin/rm -rf "$scratch_dir"
  fi
}
trap cleanup EXIT

cd "$project_dir"
if ! security find-identity -v -p codesigning \
  | /usr/bin/grep -Fq "$signing_identity"; then
  echo "code-signing identity is unavailable: $signing_identity" >&2
  exit 2
fi

if [[ "$distribution_build" != 0 && "$distribution_build" != 1 ]]; then
  echo "AGENT_GUARD_DISTRIBUTION must be 0 or 1" >&2
  exit 2
fi

if [[ "$distribution_build" == 1 ]] && ! security find-identity -v -p codesigning \
  | /usr/bin/grep -F "$signing_identity" \
  | /usr/bin/grep -Fq 'Developer ID Application'; then
  echo "distribution builds require a Developer ID Application identity" >&2
  exit 2
fi

arch_args=()
if [[ -n "${AGENT_GUARD_ARCHS:-}" ]]; then
  for arch in ${=AGENT_GUARD_ARCHS}; do
    case "$arch" in
      arm64|x86_64)
        arch_args+=(--arch "$arch")
        ;;
      *)
        echo "unsupported architecture in AGENT_GUARD_ARCHS: $arch" >&2
        exit 2
        ;;
    esac
  done
fi

build_args=(
  -c release
  --scratch-path "$scratch_dir/swift"
  -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/src/AgentGuard"
  -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/src/AgentGuard"
  -Xswiftc -debug-prefix-map -Xswiftc "$scratch_dir=/build/AgentGuard"
  -Xswiftc -file-prefix-map -Xswiftc "$scratch_dir=/build/AgentGuard"
  "${arch_args[@]}"
)

codesign_args=(
  --force
  --sign "$signing_identity"
)
if [[ "$distribution_build" == 1 ]]; then
  codesign_args+=(--options runtime --timestamp)
else
  codesign_args+=(--timestamp=none)
fi

"$project_dir/build-icon.sh"
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
binary_path="$binary_dir/AgentGuard"
cli_binary_path="$binary_dir/agent-guard"

mkdir -p "$temporary_app/Contents/MacOS"
mkdir -p "$temporary_app/Contents/Resources"
cp "$binary_path" "$temporary_app/Contents/MacOS/AgentGuard"
cp "$cli_binary_path" "$temporary_app/Contents/MacOS/agent-guard"
cp "$project_dir/AppInfo.plist" "$temporary_app/Contents/Info.plist"
cp "$project_dir/Resources/AgentGuard.icns" "$temporary_app/Contents/Resources/AgentGuard.icns"
chmod 755 \
  "$temporary_app/Contents/MacOS/AgentGuard" \
  "$temporary_app/Contents/MacOS/agent-guard"

xattr -cr "$temporary_app"
codesign \
  "${codesign_args[@]}" \
  "$temporary_app/Contents/MacOS/agent-guard"
codesign \
  --deep \
  "${codesign_args[@]}" \
  "$temporary_app"
codesign --verify --deep --strict --verbose=2 "$temporary_app"

if [[ "$distribution_build" == 1 ]]; then
  signature_details="$(codesign --display --verbose=4 "$temporary_app" 2>&1)"
  print -r -- "$signature_details" | /usr/bin/grep -Fq 'runtime'
  print -r -- "$signature_details" | /usr/bin/grep -Fq 'Timestamp='
fi

mkdir -p "$output_dir"
if [[ -e "$archive_path" ]]; then
  echo "output archive already exists: $archive_path" >&2
  exit 2
fi

(
  cd "$scratch_dir"
  /usr/bin/zip -qry -X "$archive_path" "Agent Guard.app"
)

mkdir -p "$scratch_dir/verify"
/usr/bin/unzip -q "$archive_path" -d "$scratch_dir/verify"
xattr -cr "$scratch_dir/verify/Agent Guard.app"
codesign --verify --deep --strict --verbose=2 "$scratch_dir/verify/Agent Guard.app"

echo "$archive_path"
