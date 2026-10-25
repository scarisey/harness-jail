#!/usr/bin/env bash

SCRIPTNAME=$(basename "$0")
RUNDIR=$(dirname "$(realpath $0)")

cd $RUNDIR/packages/copilot
./update.sh

cd $RUNDIR/packages/headroom
./update.sh
