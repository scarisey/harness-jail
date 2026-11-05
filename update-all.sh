#!/usr/bin/env bash

set -euo pipefail

RUNDIR=$(cd "$(dirname "$0")" && pwd)

cd "$RUNDIR/packages/copilot"
./update.sh

cd "$RUNDIR/packages/headroom"
./update.sh

cd "$RUNDIR/packages/litellm"
./update.sh
