#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
if (( $# != 1 )); then
  echo "usage: $0 /absolute/output/directory" >&2
  exit 2
fi

output_dir="$1"
if [[ "$output_dir" != /* ]]; then
  echo "output directory must be an absolute path" >&2
  exit 2
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/AppInfo.plist")"
archive_name="Agent Guard-$version.zip"
package_name="Agent Guard-$version.pkg"
checksums_name="Agent Guard-$version-SHA256SUMS.txt"
archive_path="$output_dir/$archive_name"
package_path="$output_dir/$package_name"
checksums_path="$output_dir/$checksums_name"

application_identity="${AGENT_GUARD_SIGNING_IDENTITY:-}"
installer_identity="${AGENT_GUARD_INSTALLER_SIGNING_IDENTITY:-}"
if [[ -z "$application_identity" || -z "$installer_identity" ]]; then
  echo "AGENT_GUARD_SIGNING_IDENTITY and AGENT_GUARD_INSTALLER_SIGNING_IDENTITY are required" >&2
  exit 2
fi

notary_args=()
if [[ -n "${AGENT_GUARD_NOTARY_PROFILE:-}" ]]; then
  notary_args+=(--keychain-profile "$AGENT_GUARD_NOTARY_PROFILE")
elif [[ -n "${AGENT_GUARD_NOTARY_KEY_PATH:-}" && -n "${AGENT_GUARD_NOTARY_KEY_ID:-}" ]]; then
  notary_args+=(
    --key "$AGENT_GUARD_NOTARY_KEY_PATH"
    --key-id "$AGENT_GUARD_NOTARY_KEY_ID"
  )
  if [[ -n "${AGENT_GUARD_NOTARY_ISSUER_ID:-}" ]]; then
    notary_args+=(--issuer "$AGENT_GUARD_NOTARY_ISSUER_ID")
  fi
else
  echo "configure AGENT_GUARD_NOTARY_PROFILE or the notary API key variables" >&2
  exit 2
fi

for path in "$archive_path" "$package_path" "$checksums_path"; do
  if [[ -e "$path" ]]; then
    echo "output already exists: $path" >&2
    exit 2
  fi
done

scratch_dir="$(/usr/bin/mktemp -d /private/tmp/agentguard-release.XXXXXX)"
app_build_dir="$scratch_dir/app-build"
stapled_dir="$scratch_dir/stapled"
package_build_dir="$scratch_dir/package-build"
app_bundle="$stapled_dir/Agent Guard.app"

cleanup() {
  if [[ "$scratch_dir" == /private/tmp/agentguard-release.* && -d "$scratch_dir" ]]; then
    /bin/rm -rf "$scratch_dir"
  fi
}
trap cleanup EXIT

mkdir -p "$app_build_dir" "$stapled_dir" "$package_build_dir" "$output_dir"

AGENT_GUARD_DISTRIBUTION=1 \
AGENT_GUARD_ARCHS="${AGENT_GUARD_ARCHS:-arm64 x86_64}" \
AGENT_GUARD_SIGNING_IDENTITY="$application_identity" \
  "$project_dir/build-app.sh" "$app_build_dir"

unsigned_archive="$app_build_dir/$archive_name"
/usr/bin/unzip -q "$unsigned_archive" -d "$stapled_dir"
/usr/bin/lipo -verify_arch arm64 x86_64 "$app_bundle/Contents/MacOS/AgentGuard"
/usr/bin/lipo -verify_arch arm64 x86_64 "$app_bundle/Contents/MacOS/agent-guard"

/usr/bin/xcrun notarytool submit \
  "$unsigned_archive" \
  "${notary_args[@]}" \
  --wait \
  --timeout 30m \
  --no-progress

/usr/bin/xcrun stapler staple -v "$app_bundle"
/usr/bin/xcrun stapler validate -v "$app_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_bundle"

COPYFILE_DISABLE=1 /usr/bin/ditto \
  -c -k --keepParent \
  "$app_bundle" \
  "$archive_path"

AGENT_GUARD_INSTALLER_SIGNING_IDENTITY="$installer_identity" \
  "$project_dir/build-pkg.sh" "$package_build_dir" "$archive_path"

staged_package="$package_build_dir/$package_name"
/usr/bin/xcrun notarytool submit \
  "$staged_package" \
  "${notary_args[@]}" \
  --wait \
  --timeout 30m \
  --no-progress
/usr/bin/xcrun stapler staple -v "$staged_package"
/usr/bin/xcrun stapler validate -v "$staged_package"
/usr/sbin/pkgutil --check-signature "$staged_package"
/usr/sbin/spctl --assess --type install --verbose=4 "$staged_package"
/bin/cp "$staged_package" "$package_path"

(
  cd "$output_dir"
  /usr/bin/shasum -a 256 "$archive_name" "$package_name" > "$checksums_name"
)

echo "$archive_path"
echo "$package_path"
echo "$checksums_path"
