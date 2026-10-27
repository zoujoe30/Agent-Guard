#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
master_path="$project_dir/Assets/AgentGuardIcon-1024.png"
iconset_path="$project_dir/Assets/AgentGuard.iconset"
icns_path="$project_dir/Resources/AgentGuard.icns"

if [[ ! -f "$master_path" ]]; then
  echo "missing icon master: $master_path" >&2
  exit 2
fi

/bin/mkdir -p "$iconset_path"

/usr/bin/sips -z 16 16 "$master_path" --out "$iconset_path/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$master_path" --out "$iconset_path/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$master_path" --out "$iconset_path/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$master_path" --out "$iconset_path/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$master_path" --out "$iconset_path/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$master_path" --out "$iconset_path/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$master_path" --out "$iconset_path/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$master_path" --out "$iconset_path/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$master_path" --out "$iconset_path/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$master_path" --out "$iconset_path/icon_512x512@2x.png" >/dev/null

/usr/bin/iconutil -c icns "$iconset_path" -o "$icns_path"

/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha "$master_path"
/usr/bin/file "$icns_path"
