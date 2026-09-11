# SPDX-License-Identifier: MIT
#
# Shared test fixture: a scratch shpack world (repo, store, distfiles,
# config, externals) in a temp dir, plus tiny assertion helpers. Each test
# sources this and builds its own toy packages with mkpkg.

set -e

TESTROOT=$(cd "$(dirname "$0")/.." && pwd)
TESTDIR=$(mktemp -d /tmp/shpack-test.XXXXXX)
trap 'rm -rf "$TESTDIR"' EXIT

# shpack's configuration is its environment (what bootstrap/start.kaem exports
# in a real run); the fixture plays that role here.
export ROOT="$TESTDIR"
export STORE="$TESTDIR/store"
export DISTFILES="$TESTDIR/distfiles"
export BUILDDIR="$TESTDIR"
export ARCH=testarch
export JOBS=2
export BASEPATH="$PATH"
export CONFIG_SHELL="$(command -v sh)"
export SHPACK_VAR="$TESTDIR/var"
export SHPACK_REPO="$TESTDIR/repo"
export SHPACK_EXTERNALS="$TESTDIR/externals"
# Unsandboxed, no shebang rewriting, and no two-stage make (t-install opts in):
# etc/config yields to these empty-but-set values.
export SANDBOX= PATCH_SHEBANGS= SHPACK_BOOTSTRAP_MAKE=

mkdir -p "$TESTDIR/store" "$TESTDIR/distfiles" "$SHPACK_REPO"
: > "$SHPACK_EXTERNALS"

# builder.sh requires every built node to declare a shell dep. Provide a 'dash'
# external whose bin/sh is the host shell so fixtures can `depends_on dash`;
# TEST_DASH_SH is the path a build sees as $sh.
mkdir -p "$TESTDIR/store/dash/bin"
ln -sf "$(command -v sh)" "$TESTDIR/store/dash/bin/sh"
printf 'dash@host %s\n' "$TESTDIR/store/dash" >> "$SHPACK_EXTERNALS"
export TEST_DASH_SH="$TESTDIR/store/dash/bin/sh"

shpack() {
    sh "$TESTROOT/bin/shpack" "$@"
}

# mkpkg NAME -- create a package dir, recipe body on stdin.
mkpkg() {
    mkdir -p "$SHPACK_REPO/$1"
    cat > "$SHPACK_REPO/$1/package.sh"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {  # actual expected message
    if [ "$1" != "$2" ]; then
        fail "$3: expected '$2', got '$1'"
    fi
}

assert_file() {
    if [ ! -f "$1" ]; then
        fail "expected file $1 to exist"
    fi
}

assert_contains() {  # file string
    case $(cat "$1") in
        *"$2"*) ;;
        *) fail "expected $1 to contain '$2'" ;;
    esac
}

# index_field NAME FIELD -> column FIELD (1=name 2=version 3=hash 4=kind
# 5=prefix) of NAME's line in the concretized index.
index_field() {
    local n v h k p
    while read -r n v h k p; do
        if [ "$n" = "$1" ]; then
            eval "printf '%s\n' \"\$$(field_var "$2")\""
            return 0
        fi
    done < "$SHPACK_VAR/index"
    return 1
}

field_var() {
    case $1 in
        1) echo n ;;
        2) echo v ;;
        3) echo h ;;
        4) echo k ;;
        5) echo p ;;
    esac
}
