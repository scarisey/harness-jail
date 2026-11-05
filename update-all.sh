#!/usr/bin/env bash

set -euo pipefail

RUNDIR=$(dirname "$(realpath "$0")")

cd "$RUNDIR/packages/copilot"
./update.sh

cd "$RUNDIR/packages/headroom"
./update.sh

cd "$RUNDIR/packages/litellm"
./update.sh
