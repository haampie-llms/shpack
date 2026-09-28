# SPDX-License-Identifier: MIT
# Tool-budget lint: shpack core runs under dash + coreutils 5.0 + sed +
# make 3.82 + the stage0 sha256sum. These commands do not exist at
# shell-phase start (or are banned for determinism) and must never appear in
# bin/ or lib/: grep, awk, find, xargs, expr, cut, tac, mktemp.
# (This test itself runs on the host, so it may use grep.)

set -e
cd "$(dirname "$0")/.."

bad=0
for f in bin/shpack lib/*.sh lib/build_systems/*.sh; do
    # Strip comment lines and the usage text (which mentions `find`), then
    # look for the banned words in command-ish positions.
    if sed -e '/^[ \t]*#/d' -e '/^usage() {/,/^}/d' "$f" \
        | grep -nE '(^|[ \t(|;&!`])(grep|awk|gawk|find|xargs|expr|cut|tac|mktemp)([ \t]|$)'; then
        echo "banned command in $f (above)" >&2
        bad=1
    fi
done

# Every built recipe must declare a shell dep: builder.sh requires it (the build
# always runs make/patch-shebangs) and there is no ambient-shell fallback.
for f in packages/*/package.sh; do
    [ -f "$f" ] || continue
    if ! grep -qE '^depends_on .*\bdash\b' "$f"; then
        echo "no dash dependency in $f" >&2
        bad=1
    fi
done
for f in packages/*/package.star; do
    [ -f "$f" ] || continue
    if ! grep -qE '^depends_on\(.*"dash(@[^"]*)?"' "$f"; then
        echo "no dash dependency in $f" >&2
        bad=1
    fi
    if [ -f "${f%.star}.sh" ]; then
        echo "${f%/*} has both package.star and package.sh" >&2
        bad=1
    fi
done

# The sh() escape hatch in Starlark recipes: allowed, but counted, so the
# number only goes down.
escapes=$(cat packages/*/package.star build_systems/*.star 2>/dev/null \
    | grep -cE '(^|[^_a-z])sh\(' || true)
echo "sh() escapes in Starlark recipes: $escapes"

[ "$bad" = 0 ] || exit 1
echo OK
