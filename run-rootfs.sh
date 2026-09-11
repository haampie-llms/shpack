#!/bin/sh
# SPDX-License-Identifier: MIT
#
# run-rootfs.sh -- the same one-exec kickoff as run-local.sh, inside a rootless
# bwrap namespace whose root holds NOTHING but this tree (bound at its own
# path), /dev and /proc. The host /usr does not exist in there, so this is the
# hermetic check: because the tree sits at the same path as on the host, a
# store built here must be byte-identical to one built by run-local.sh -- diff
# them. Per-build confinement is the Landlock sandbox either way; what this
# adds is the change of root.
#
# Needs bwrap and unprivileged user namespaces (Debian/Ubuntu restrict them:
# see README.md). The store and build dir must be under the tree (they are by
# default), since nothing else is bound in. aarch64 on x86_64 relies on the
# qemu-aarch64 binfmt handler firing inside the namespace -- a testing
# convenience, not a bootstrap.
#
#   ./run-rootfs.sh [--arch amd64|aarch64]

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
die() { echo "run-rootfs.sh: $*" >&2; exit 1; }

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
command -v bwrap > /dev/null 2>&1 || die "bwrap not found (or use ./run-local.sh, which needs no namespaces)"

exec bwrap --unshare-all --die-with-parent \
    --bind "$ROOT" "$ROOT" --dev /dev --proc /proc \
    --clearenv --chdir "$ROOT/seed" \
    "$ROOT/seed/bootstrap-seeds/POSIX/$DIR/kaem-optional-seed" "kaem.$ARCH"
