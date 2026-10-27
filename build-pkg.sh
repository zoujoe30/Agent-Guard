#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
if (( $# < 1 || $# > 2 )); then
  echo "usage: $0 /absolute/output/directory [/absolute/path/to/Agent\\ Guard-<version>.zip]" >&2
  exit 2
fi

output_dir="$1"
if [[ "$output_dir" != /* ]]; then
  echo "output directory must be an absolute path" >&2
  exit 2
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/AppInfo.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project_dir/AppInfo.plist")"
expected_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_dir/AppInfo.plist")"
source_archive="${2:-$project_dir/Releases/Agent Guard-$version.zip}"
package_path="$output_dir/Agent Guard-$version.pkg"
package_id="$expected_bundle_id.pkg"
installer_identity="${AGENT_GUARD_INSTALLER_SIGNING_IDENTITY:-}"
scratch_dir="$(/usr/bin/mktemp -d /private/tmp/agentguard-pkg.XXXXXX)"
app_bundle="$scratch_dir/Agent Guard.app"
unsigned_package="$scratch_dir/Agent Guard-$version-unsigned.pkg"

cleanup() {
  if [[ "$scratch_dir" == /private/tmp/agentguard-pkg.* && -d "$scratch_dir" ]]; then
    /bin/rm -rf "$scratch_dir"
  fi
}
trap cleanup EXIT

if [[ "$source_archive" != /* || ! -f "$source_archive" ]]; then
  echo "source archive does not exist or is not an absolute path: $source_archive" >&2
  exit 2
fi

mkdir -p "$output_dir"
if [[ -e "$package_path" ]]; then
  echo "output package already exists: $package_path" >&2
  exit 2
fi

/usr/bin/unzip -q "$source_archive" -d "$scratch_dir"
if [[ ! -d "$app_bundle" ]]; then
  echo "source archive does not contain Agent Guard.app" >&2
  exit 2
fi

/usr/bin/xattr -cr "$app_bundle"

archive_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")"
archive_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")"
archive_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")"

if [[ "$archive_version" != "$version" || "$archive_build" != "$build_number" ]]; then
  echo "source archive version mismatch: expected $version ($build_number), got $archive_version ($archive_build)" >&2
  exit 2
fi
if [[ "$archive_bundle_id" != "$expected_bundle_id" ]]; then
  echo "source archive bundle identifier mismatch: expected $expected_bundle_id, got $archive_bundle_id" >&2
  exit 2
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"

pkgbuild_output="$package_path"
if [[ -n "$installer_identity" ]]; then
  if ! security find-identity -v \
    | /usr/bin/grep -F "$installer_identity" \
    | /usr/bin/grep -Fq 'Developer ID Installer'; then
    echo "installer signing identity is unavailable or is not Developer ID Installer: $installer_identity" >&2
    exit 2
  fi
  pkgbuild_output="$unsigned_package"
fi

COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 /usr/bin/pkgbuild \
  --component "$app_bundle" \
  --install-location /Applications \
  --identifier "$package_id" \
  --version "$version" \
  --ownership recommended \
  "$pkgbuild_output"

if [[ -n "$installer_identity" ]]; then
  /usr/bin/productsign \
    --sign "$installer_identity" \
    --timestamp \
    "$unsigned_package" \
    "$package_path"
  /usr/sbin/pkgutil --check-signature "$package_path"
fi

# Materialize the listing before matching: grep -q can close the pipe early
# and make pkgutil fail with SIGPIPE under pipefail for large frameworks.
/usr/sbin/pkgutil --payload-files "$package_path" > "$scratch_dir/payload-files.txt"
if ! /usr/bin/grep -Fxq './Agent Guard.app/Contents/MacOS/AgentGuard' "$scratch_dir/payload-files.txt"; then
  echo "package payload is missing Agent Guard.app" >&2
  exit 3
fi

echo "$package_path"
