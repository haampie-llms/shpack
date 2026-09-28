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
ah=$(index_field liba 3)
aprefix=$(index_field liba 5)
tprefix=$(index_field tarpkg 5)
assert_file "$aprefix/bin/liba-cmd"
assert_file "$tprefix/share/hello.txt"
# metadata as Spack keeps it, in .spack/
assert_file "$tprefix/.spack/spec.json"
assert_file "$tprefix/.spack/shpack-manifest"
assert_file "$tprefix/.spack/repos/shpack/packages/tarpkg/package.star"
assert_file "$tprefix/.spack/shpack-build.sh"
assert_file "$tprefix/.spack/spack-build-out.txt"
assert_contains "$tprefix/.spack/spec.json" '"name": "tarpkg"'
assert_contains "$tprefix/.spack/spec.json" "\"hash\": \"$ah"

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

# The store is a Spack install tree: .spack-db/index.json lists every installed
# node under its Spack hash, whose first 7 characters name its prefix, with
# the dependencies by hash; the root is explicit. Each prefix has .spack/spec.json.
db=$STORE/.spack-db/index.json
assert_file "$db"
assert_file "$tprefix/.spack/spec.json"
if command -v python3 > /dev/null 2>&1; then
    python3 - "$db" "$STORE" "$tprefix" <<'PY' || fail "bad Spack database"
import json, sys
db = json.load(open(sys.argv[1]))["database"]
assert db["version"] == "9", db["version"]
recs = {r["spec"]["name"]: (h, r) for h, r in db["installs"].items()}
h, tar = recs["tarpkg"]
assert tar["installed"] and tar["explicit"], tar
# Spack's default layout: {platform}-{target}/{name}-{version}-{hash}
assert tar["path"] == sys.argv[3] == "%s/linux-testarch/tarpkg-1.0-%s" % (sys.argv[2], h), tar["path"]
assert len(h) == 32 and tar["spec"]["hash"] == h
deps = {d["name"]: d for d in tar["spec"]["dependencies"]}
assert deps["liba"]["hash"] == recs["liba"][0] and deps["liba"]["parameters"]["deptypes"] == ["build", "link"]
assert not recs["liba"][1]["explicit"] and recs["liba"][1]["ref_count"] >= 1
assert recs["dash"][1]["spec"]["external"]["path"], recs["dash"]
for h, r in db["installs"].items():
    for d in r["spec"].get("dependencies", []):
        assert d["hash"] in db["installs"], (r["spec"]["name"], d)
PY
fi

# The database is merged into, not rewritten: a record Spack owns (here a
# made-up one) survives the next shpack install.
if command -v python3 > /dev/null 2>&1; then
    python3 - "$db" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
h = "a" * 32
d["database"]["installs"][h] = {"spec": {"name": "foreign", "version": "1", "hash": h},
    "ref_count": 0, "path": "/elsewhere", "installed": True, "explicit": True,
    "installation_time": 1.5, "deprecated_for": None}
json.dump(d, open(sys.argv[1], "w"))
PY
    shpack install tarpkg > "$TESTDIR/install4.log" 2>&1 || fail "install after a Spack record"
    python3 - "$db" <<'PY' || fail "the database lost a record"
import json, sys
installs = json.load(open(sys.argv[1]))["database"]["installs"]
assert installs["a" * 32]["path"] == "/elsewhere"
assert [r for r in installs.values() if r["spec"]["name"] == "tarpkg"][0]["explicit"]
PY
fi

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
