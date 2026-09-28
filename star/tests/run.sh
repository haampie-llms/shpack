#!/bin/sh
# SPDX-License-Identifier: MIT
#
# star's test suite (host side): build star with $CC (default cc), then
#   1. starlark-go's conformance tests (starlark-go/*.star, BSD-3, see
#      starlark-go/UPSTREAM), minus the lines in starlark-go/exclusions;
#   2. star's own tests (*.star here), in the same chunked format.
# Exit status is the result.

set -e
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d /tmp/star-test.XXXXXX)
trap 'rm -rf "$work"' EXIT

CC=${CC:-cc}
STAR=${STAR:-$work/star}
if [ ! -x "$STAR" ]; then
    $CC -O1 -g -o "$STAR" "$here/../star.c"
fi

mkdir -p "$work/sg"
cp "$here/starlark-go/assert.star" "$work/sg/"
for f in "$here"/starlark-go/*.star; do
    b=${f##*/}
    [ "$b" = assert.star ] && continue
    # blank the excluded line ranges, keeping line numbers
    ranges=$(awk -v f="$b" '$1 == f { printf "%s ", $2 }' "$here/starlark-go/exclusions")
    awk -v r="$ranges" '
        BEGIN { n = split(r, rs, " ") }
        {
            for (i = 1; i <= n; i++) {
                if (rs[i] == "") continue
                split(rs[i], lh, "-"); lo = lh[1]; hi = (lh[2] == "" ? lh[1] : lh[2])
                if (NR >= lo + 0 && NR <= hi + 0) { print ""; next }
            }
            print
        }' "$f" > "$work/sg/$b"
done

fail=0
for f in "$work"/sg/*.star "$here"/*.star; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = assert.star ] && continue
    if [ "${f%/*}" = "$here" ]; then
        cp "$f" "$work/sg/${f##*/}"
        f=$work/sg/${f##*/}
    fi
    if out=$(cd "$work/sg" && "$STAR" test "${f##*/}" 2>&1); then
        printf 'ok   %s\n' "${f##*/}"
    else
        printf 'FAIL %s\n%s\n' "${f##*/}" "$out"
        fail=1
    fi
done
exit $fail
