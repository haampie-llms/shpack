#!/bin/sh
# SPDX-License-Identifier: MIT
#
# run-local.sh -- a convenience spelling of the one-exec kickoff:
#
#   cd seed && exec bootstrap-seeds/POSIX/<AMD64|AArch64>/kaem-optional-seed kaem.<amd64|aarch64>
#
# That line IS the whole bootstrap: the stage0 seed builds the mescc-tools,
# seed/after.kaem builds shpack's kaem, and shpack/bootstrap/start.kaem derives
# every path from the tree's own location, reads ./shpack.conf, builds the
# kaem-phase base into the store and execs shpack on the store dash. No other
# host tool is involved; this script only picks the arch for you. Run
# ./fetch-distfiles.sh first (or ship distfiles/ with the tree).
#
#   ./run-local.sh                  # host arch
#   ./run-local.sh --arch aarch64   # on x86_64 only under qemu-user (binfmt):
#                                   # a testing convenience, not a bootstrap
#
# Store (default ./store), build dir (./tmp), distfiles, JOBS and what to run
# come from ./shpack.conf, see shpack.conf.example. Re-running rebuilds the
# kaem-phase base (a few minutes) and then only what the store lacks. One run
# at a time: store and state are shared on disk.

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
die() { echo "run-local.sh: $*" >&2; exit 1; }

ARCH=
case ${1:-} in
    --arch) [ $# -eq 2 ] || die "usage: $0 [--arch amd64|aarch64]"; ARCH=$2 ;;
    '') ;;
    *) die "usage: $0 [--arch amd64|aarch64]" ;;
esac
[ -n "$ARCH" ] || ARCH=$(uname -m)
case $ARCH in
    amd64|x86_64)  ARCH=amd64;   DIR=AMD64 ;;
    aarch64|arm64) ARCH=aarch64; DIR=AArch64 ;;
    *) die "unsupported arch: $ARCH (want amd64 or aarch64)" ;;
esac

[ -d "$ROOT/distfiles" ] || die "no distfiles at $ROOT/distfiles -- run ./fetch-distfiles.sh first"

cd "$ROOT/seed"
exec "./bootstrap-seeds/POSIX/$DIR/kaem-optional-seed" "kaem.$ARCH"
