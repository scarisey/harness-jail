#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "error: $name is empty" >&2
    exit 1
  fi
}

CURRENT_VERSION=$(jq -er '.version | select(type == "string" and length > 0)' headroom-versions.json)
echo "Current version: $CURRENT_VERSION"

PYPI_JSON=$(curl -fsS https://pypi.org/pypi/headroom-ai/json)
LATEST_VERSION=$(printf '%s' "$PYPI_JSON" | jq -er '.info.version | select(type == "string" and length > 0)')
require_value "latest version" "$LATEST_VERSION"
echo "Latest version:  $LATEST_VERSION"

to_sri() {
  local hex="$1"
  local sri
  sri=$(nix hash to-sri --type sha256 "$hex")
  require_value "SRI hash" "$sri"
  printf '%s\n' "$sri"
}

# Extract a field (jq path expression, e.g. ".url" or ".digests.sha256") of the
# wheel whose filename matches the given regex pattern
wheel_field() {
  local pattern="$1"
  local field="$2"
  # Return exactly one value so `head` cannot close the pipe early and trip
  # `pipefail`. An empty result is rejected by require_value below.
  printf '%s' "$PYPI_JSON" | jq -r --arg pattern "$pattern" \
    "[.releases[\$ENV.LATEST_VERSION][] | select(.filename | test(\$pattern)) | $field] | first // \"\""
}

# Check if update is needed
if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
  tmpFile=$(mktemp)
  trap 'rm -f "$tmpFile"' EXIT

  echo "Fetching hashes for all platforms..."
  export LATEST_VERSION
  URL_LINUX_X64=$(wheel_field 'manylinux.*x86_64\.whl$' '.url')
  URL_LINUX_ARM64=$(wheel_field 'manylinux.*aarch64\.whl$' '.url')
  URL_DARWIN_ARM64=$(wheel_field 'macosx.*arm64\.whl$' '.url')

  SHA256_HEX_LINUX_X64=$(wheel_field 'manylinux.*x86_64\.whl$' '.digests.sha256')
  SHA256_HEX_LINUX_ARM64=$(wheel_field 'manylinux.*aarch64\.whl$' '.digests.sha256')
  SHA256_HEX_DARWIN_ARM64=$(wheel_field 'macosx.*arm64\.whl$' '.digests.sha256')

  require_value "Linux x86_64 URL" "$URL_LINUX_X64"
  require_value "Linux aarch64 URL" "$URL_LINUX_ARM64"
  require_value "Darwin aarch64 URL" "$URL_DARWIN_ARM64"
  require_value "Linux x86_64 hash" "$SHA256_HEX_LINUX_X64"
  require_value "Linux aarch64 hash" "$SHA256_HEX_LINUX_ARM64"
  require_value "Darwin aarch64 hash" "$SHA256_HEX_DARWIN_ARM64"

  SHA256_LINUX_X64=$(to_sri "$SHA256_HEX_LINUX_X64")
  SHA256_LINUX_ARM64=$(to_sri "$SHA256_HEX_LINUX_ARM64")
  SHA256_DARWIN_ARM64=$(to_sri "$SHA256_HEX_DARWIN_ARM64")

  jq \
    --arg v   "$LATEST_VERSION" \
    --arg lxu "$URL_LINUX_X64" \
    --arg lau "$URL_LINUX_ARM64" \
    --arg dau "$URL_DARWIN_ARM64" \
    --arg lx  "$SHA256_LINUX_X64" \
    --arg la  "$SHA256_LINUX_ARM64" \
    --arg da  "$SHA256_DARWIN_ARM64" \
    '.version=$v | .urlLinux_x64=$lxu | .urlLinux_arm64=$lau | .urlDarwin_arm64=$dau | .sha256Linux_x64=$lx | .sha256Linux_arm64=$la | .sha256Darwin_arm64=$da' \
    headroom-versions.json > "$tmpFile"
  jq -e '.version and .urlLinux_x64 and .urlLinux_arm64 and .urlDarwin_arm64 and .sha256Linux_x64 and .sha256Linux_arm64 and .sha256Darwin_arm64' "$tmpFile" >/dev/null
  mv "$tmpFile" headroom-versions.json
  trap - EXIT

  echo "Updated headroom-versions.json:"
  cat headroom-versions.json
else
  echo "No update needed"
fi
