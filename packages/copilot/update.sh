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

CURRENT_VERSION=$(jq -er '.version | select(type == "string" and length > 0)' versions.json)
echo "Current version: $CURRENT_VERSION"
LATEST_VERSION=$(npm view @github/copilot version)
require_value "latest version" "$LATEST_VERSION"
echo "Latest version:  $LATEST_VERSION"

fetch_sri() {
  local url="$1"
  local raw
  local sri
  raw=$(nix-prefetch-url --type sha256 "$url")
  sri=$(nix hash to-sri --type sha256 "$raw")
  require_value "hash for $url" "$sri"
  printf '%s\n' "$sri"
}

# Check if update is needed
if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
  tmpFile=$(mktemp)
  trap 'rm -f "$tmpFile"' EXIT

  echo "Fetching hashes for all platforms..."
  SHA256_LINUX_X64=$(fetch_sri   "https://registry.npmjs.org/@github/copilot-linux-x64/-/copilot-linux-x64-${LATEST_VERSION}.tgz")
  SHA256_LINUX_ARM64=$(fetch_sri "https://registry.npmjs.org/@github/copilot-linux-arm64/-/copilot-linux-arm64-${LATEST_VERSION}.tgz")
  SHA256_DARWIN_ARM64=$(fetch_sri "https://registry.npmjs.org/@github/copilot-darwin-arm64/-/copilot-darwin-arm64-${LATEST_VERSION}.tgz")

  jq \
    --arg v   "$LATEST_VERSION" \
    --arg lx  "$SHA256_LINUX_X64" \
    --arg la  "$SHA256_LINUX_ARM64" \
    --arg da  "$SHA256_DARWIN_ARM64" \
    '.version=$v | .sha256Linux_x64=$lx | .sha256Linux_arm64=$la | .sha256Darwin_arm64=$da' \
    versions.json > "$tmpFile"
  jq -e '.version and .sha256Linux_x64 and .sha256Linux_arm64 and .sha256Darwin_arm64' "$tmpFile" >/dev/null
  mv "$tmpFile" versions.json
  trap - EXIT

  echo "Updated versions.json:"
  cat versions.json
else
  echo "No update needed"
fi
