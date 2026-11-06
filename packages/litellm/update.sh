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

CURRENT_VERSION=$(sed -n 's/.*litellm\[[^]]*\]==\([0-9][0-9.]*\).*/\1/p' pyproject.toml | head -n1)
require_value "current version" "$CURRENT_VERSION"
echo "Current version: $CURRENT_VERSION"
LATEST_VERSION=$(curl -fsS https://pypi.org/pypi/litellm/json | jq -er '.info.version | select(type == "string" and length > 0)')
require_value "latest version" "$LATEST_VERSION"
echo "Latest version:  $LATEST_VERSION"

# Check if update is needed
if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
  tmpFile=$(mktemp)
  trap 'rm -f "$tmpFile"' EXIT

  sed "s/\(litellm\[[^]]*\]==\)[0-9.]*/\1${LATEST_VERSION}/" pyproject.toml > "$tmpFile"
  grep -q "litellm\[[^]]*\]==${LATEST_VERSION}" "$tmpFile"
  mv "$tmpFile" pyproject.toml
  trap - EXIT

  echo "Re-locking dependencies..."
  uv lock --upgrade-package litellm

  echo "Updated pyproject.toml:"
  cat pyproject.toml
else
  echo "No update needed"
fi
