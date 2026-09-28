# SPDX-License-Identifier: MIT
# End-to-end install on the host: fetch/stage a real tarball, dep PATH
# composition, store metadata, idempotency, two-stage bootstrap make.

. "$(dirname "$0")/common.sh"

# A real source tarball for the fetch+stage path.
mkdir -p "$TESTDIR/src/tarpkg-1.0"
echo "payload" > "$TESTDIR/src/tarpkg-1.0/hello.txt"
( cd "$TESTDIR/src" && tar -czf "$TESTDIR/distfiles/tarpkg-1.0.tar.gz" tarpkg-1.0 )
sha=$(sha256sum "$TESTDIR/distfiles/tarpkg-1.0.tar.gz")
sha=${sha%% *}

mkstar liba <<'EOF'
version("1.0")
build_system("generic")
depends_on("dash")
def install(ctx):
    return [
        mkdir(ctx.prefix + "/bin"),
        write_file(ctx.prefix + "/bin/liba-cmd", "#!" + ctx.sh + "\necho liba-says-hi\n", mode = "755"),
    ]
EOF

# gmake stand-in: exercises SHPACK_BOOTSTRAP_MAKE's two-stage scheduling.
mkstar gmake <<'EOF'
version("4.4.1")
build_system("generic")
depends_on("liba")
depends_on("dash")
def install(ctx):
    return [mkdir(ctx.prefix + "/bin")]
EOF

mkstar tarpkg <<EOF
version(
    "1.0",
    sha256 = "$sha",
    url = "http://example.invalid/tarpkg-1.0.tar.gz",
)
build_system("generic")
depends_on("liba")
depends_on("gmake@4.4.1")
depends_on("dash")
def install(ctx):
    return [
        # Runs inside the unpacked source dir; the dep's bin must be on PATH.
        run("test", "-f", "hello.txt"),
        run("liba-cmd", stdout = "/dev/null"),
        mkdir(ctx.prefix + "/share"),
        copy("hello.txt", ctx.prefix + "/share/"),
    ]
EOF

export SHPACK_BOOTSTRAP_MAKE=gmake@4.4.1

shpack install tarpkg > "$TESTDIR/install.log" 2>&1 \
    || { cat "$TESTDIR/install.log"; fail "install failed"; }

# Store contents + metadata.
ah=$(index_field liba 3); th=$(index_field tarpkg 3)
aprefix=$TESTDIR/store/liba-1.0-$ah
tprefix=$TESTDIR/store/tarpkg-1.0-$th
assert_file "$aprefix/bin/liba-cmd"
assert_file "$tprefix/share/hello.txt"
assert_file "$tprefix/.shpack/spec"
assert_file "$tprefix/.shpack/manifest"
assert_file "$tprefix/.shpack/package.star"
assert_file "$tprefix/.shpack/build.sh"
assert_file "$tprefix/.shpack/build.log"
assert_contains "$tprefix/.shpack/spec" "name tarpkg"
assert_contains "$tprefix/.shpack/deps" "liba-1.0-$ah"

# Stage dirs are cleaned up after success.
for d in "$SHPACK_VAR/stage"/*; do
    if [ -e "$d" ]; then fail "stage dir $d not cleaned"; fi
done

# Idempotency layer 1: with stamps intact, make skips everything.
shpack install tarpkg > "$TESTDIR/install2.log" 2>&1 \
    || { cat "$TESTDIR/install2.log"; fail "stamped re-install failed"; }
case $(cat "$TESTDIR/install2.log") in
    *"=> tarpkg"*) fail "stamped re-install must not re-run build-one" ;;
esac

# Idempotency layer 2: stamps gone (fresh chroot/VAR), build-one finds the
# spec already in the store and short-circuits.
rm -rf "$SHPACK_VAR/stamps"
shpack install tarpkg > "$TESTDIR/install3.log" 2>&1 \
    || { cat "$TESTDIR/install2.log"; fail "re-install failed"; }
assert_contains "$SHPACK_VAR/logs/tarpkg-1.0.log" "already installed"

# Corrupt distfile is rejected.
mkstar badpkg <<EOF
version(
    "1.0",
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    url = "-",
    fname = "tarpkg-1.0.tar.gz",
)
build_system("generic")
depends_on("dash")
def install(ctx):
    return []
EOF
if shpack install badpkg > /dev/null 2>&1; then
    fail "expected bad checksum to fail the build"
fi

echo OK
