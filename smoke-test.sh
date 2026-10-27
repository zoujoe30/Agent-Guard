#!/bin/zsh
set -euo pipefail

if (( $# < 1 )); then
  echo "usage: $0 /absolute/path/to/Agent\\ Guard-<version>.zip" >&2
  exit 2
fi

archive_path="$1"
if [[ "$archive_path" != /* || ! -f "$archive_path" ]]; then
  echo "archive does not exist or is not an absolute path: $archive_path" >&2
  exit 2
fi

scratch_dir="$(/usr/bin/mktemp -d /private/tmp/agentguard-smoke.XXXXXX)"
app_bundle="$scratch_dir/Agent Guard.app"
app_binary="$app_bundle/Contents/MacOS/AgentGuard"
cli_binary="$app_bundle/Contents/MacOS/agent-guard"
process_pid=""

cleanup() {
  if [[ -n "$process_pid" ]] && /bin/ps -p "$process_pid" >/dev/null 2>&1; then
    /bin/kill -TERM "$process_pid" 2>/dev/null || true
  fi
  if [[ "$scratch_dir" == /private/tmp/agentguard-smoke.* && -d "$scratch_dir" ]]; then
    /bin/rm -rf "$scratch_dir"
  fi
}
trap cleanup EXIT

/usr/bin/unzip -q "$archive_path" -d "$scratch_dir"
xattr -cr "$app_bundle"
/usr/bin/plutil -lint "$app_bundle/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
/usr/bin/open -g "$app_bundle"

for _ in {1..5}; do
  /bin/sleep 1
  process_line=$(/bin/ps ax -o pid=,command= | /usr/bin/grep -F "$app_binary" | /usr/bin/grep -v grep | head -1 || true)
  if [[ -n "$process_line" ]]; then
    process_pid=$(echo "$process_line" | /usr/bin/awk '{print $1}')
    break
  fi
done

if [[ -z "$process_pid" ]]; then
  echo "Agent Guard did not launch" >&2
  exit 1
fi

echo "Agent Guard launched from verified archive (pid $process_pid)"
if [[ ! -x "$cli_binary" ]]; then
  echo "Agent Guard CLI is missing or not executable" >&2
  exit 1
fi

control_status="$("$cli_binary" status)"
if [[ "$control_status" != "guard=inactive display="* ]]; then
  echo "Unexpected Agent Guard control status: $control_status" >&2
  exit 1
fi
echo "Agent Guard control interface responded: $control_status"

/bin/kill -TERM "$process_pid"
/bin/sleep 1
if /bin/ps -p "$process_pid" >/dev/null 2>&1; then
  echo "Agent Guard did not terminate cleanly" >&2
  exit 1
fi
process_pid=""
echo "Agent Guard smoke test passed"
