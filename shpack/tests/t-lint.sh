# SPDX-License-Identifier: MIT
# Tool-budget lint: shpack core runs under dash + coreutils 5.0 + sed +
# make 3.82 + the stage0 sha256sum. These commands do not exist at
# shell-phase start (or are banned for determinism) and must never appear in
# bin/ or lib/: grep, awk, find, xargs, expr, cut, tac, mktemp.
# (This test itself runs on the host, so it may use grep.)

set -e
cd "$(dirname "$0")/.."

bad=0
for f in bin/shpack lib/*.sh; do
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
for f in packages/*/package.star; do
    if ! grep -qE '^depends_on\(.*"dash(-boot)?(@[^"]*)?"' "$f"; then
        echo "no dash dependency in $f" >&2
        bad=1
    fi
done
for d in packages/*/; do
    if [ ! -f "$d/package.star" ]; then
        echo "no package.star in $d" >&2
        bad=1
    fi
done

# fetch-distfiles.sh scans package.star textually (there is no star on the
# host); its scan must agree with what star evaluates.
if [ -n "${STAR:-}" ]; then
    for f in packages/*/package.star; do
        [ -f "$f" ] || continue
        n=${f%/package.star}
        n=${n##*/}
        want=$("$STAR" recipe --repo packages --root . "$n" | awk '
            /^## / { sec = $2; next }
            sec == "versions" && $2 != "-" { print $2 "  " $3 "  " $4 }
            sec == "resources" { print $2 "  " $3 "  " $4 }' | sort)
        got=$(sh ../fetch-distfiles.sh --scan "$PWD/$f" | sort)
        if [ "$want" != "$got" ]; then
            printf 'fetch-distfiles scan of %s disagrees with star:\n%s\n--- vs ---\n%s\n' \
                "$f" "$got" "$want" >&2
            bad=1
        fi
    done
fi

# The sh() escape hatch in Starlark recipes: allowed, but counted, so the
# number only goes down.
escapes=$(cat packages/*/package.star build_systems/*.star 2>/dev/null \
    | grep -cE '(^|[^_a-z])sh\(' || true)
echo "sh() escapes in Starlark recipes: $escapes"

[ "$bad" = 0 ] || exit 1
echo OK
