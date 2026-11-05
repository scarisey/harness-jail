#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$(realpath "$0")")"

CURRENT_VERSION=$(grep -oP 'litellm\[[^]]*\]==\K[0-9.]+' pyproject.toml)
echo "Current version: $CURRENT_VERSION"
LATEST_VERSION=$(curl -s https://pypi.org/pypi/litellm/json | jq -r '.info.version')
echo "Latest version:  $LATEST_VERSION"

# Check if update is needed
if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
  sed -i "s/\(litellm\[[^]]*\]==\)[0-9.]*/\1${LATEST_VERSION}/" pyproject.toml

  echo "Re-locking dependencies..."
  uv lock --upgrade-package litellm

  echo "Updated pyproject.toml:"
  cat pyproject.toml
else
  echo "No update needed"
fi
