# SPDX-License-Identifier: MIT
# package.star builds: the makefile/autotools/generic build systems, hooks,
# per-version build systems, patches, and every action the renderer emits.

. "$(dirname "$0")/common.sh"

tarball() {  # NAME-VER: tar up $TESTDIR/src/NAME-VER, print its sha256
    ( cd "$TESTDIR/src" && tar -czf "$TESTDIR/distfiles/$1.tar.gz" "$1" )
    set -- $(sha256sum "$TESTDIR/distfiles/$1.tar.gz")
    printf '%s\n' "$1"
}

# makefile: recipe-shipped files/Makefile + a patch fixing the staged source
mkdir -p "$TESTDIR/src/mkpkg-1.0"
printf 'broken\n' > "$TESTDIR/src/mkpkg-1.0/data.in"
sha=$(tarball mkpkg-1.0)
mkstar mkpkg <<EOF2
package()
version("1.0", sha256 = "$sha", url = "http://example.invalid/mkpkg-1.0.tar.gz")
build_system("makefile")
depends_on("dash")
patch("fix-data.patch")
EOF2
mkdir -p "$SHPACK_REPO/mkpkg/files" "$SHPACK_REPO/mkpkg/patches"
cat > "$SHPACK_REPO/mkpkg/files/Makefile" <<'EOF2'
all: data.out
data.out: data.in
	cp data.in data.out
install: data.out
	mkdir -p $(PREFIX)/share
	cp data.out $(PREFIX)/share/data.out
EOF2
cat > "$SHPACK_REPO/mkpkg/patches/fix-data.patch" <<'EOF2'
--- a/data.in
+++ b/data.in
@@ -1 +1 @@
-broken
+fixed
EOF2

# autotools: a fake configure records its arguments and cwd
fakeconf() {  # DIR
    cat > "$1/configure" <<'EOF2'
#!/bin/sh
pwd > where.txt
printf '%s\n' "$@" > config.args
cat > Makefile <<'MK'
all:
	cp where.txt out.txt
	cat config.args >> out.txt
install:
	mkdir -p $(PREFIX)/share
	cp out.txt $(PREFIX)/share/
MK
EOF2
    chmod 755 "$1/configure"
}
mkdir -p "$TESTDIR/src/atpkg-2.0"
fakeconf "$TESTDIR/src/atpkg-2.0"
sha=$(tarball atpkg-2.0)
mkstar atpkg <<EOF2
package()
version("2.0", sha256 = "$sha", url = "http://example.invalid/atpkg-2.0.tar.gz")
build_system("autotools")
depends_on("dash")
parallel(False)
def configure_args(ctx):
    # arguments may contain spaces
    return ["--disable-nls", "--enable-static", "CXXCPP=tcc -E"]
def install_targets(ctx):
    return ["install"]
EOF2

# out of tree: build_directory
mkdir -p "$TESTDIR/src/ootpkg-1.0"
fakeconf "$TESTDIR/src/ootpkg-1.0"
sha=$(tarball ootpkg-1.0)
mkstar ootpkg <<EOF2
package()
version("1.0", sha256 = "$sha", url = "http://example.invalid/ootpkg-1.0.tar.gz")
build_system("autotools")
depends_on("dash")
build_directory("_build/sub")
EOF2

# per-version build systems
mkdir -p "$TESTDIR/src/bspkg-1.0" "$TESTDIR/src/bspkg-2.0"
printf 'mk\n' > "$TESTDIR/src/bspkg-1.0/data.in"
sha10=$(tarball bspkg-1.0)
fakeconf "$TESTDIR/src/bspkg-2.0"
sha20=$(tarball bspkg-2.0)
mkstar bspkg <<EOF2
package()
version("1.0", sha256 = "$sha10", url = "http://example.invalid/bspkg-1.0.tar.gz")
version("2.0", sha256 = "$sha20", url = "http://example.invalid/bspkg-2.0.tar.gz")
build_system("makefile", when = "@=1.0")
build_system("autotools", when = "@=2.0")
depends_on("dash")
EOF2
mkdir -p "$SHPACK_REPO/bspkg/files"
cp "$SHPACK_REPO/mkpkg/files/Makefile" "$SHPACK_REPO/bspkg/files/Makefile"

# generic: every action kind
mkdir -p "$TESTDIR/src/actpkg-1.0/sub/deep" "$TESTDIR/src/actpkg-1.0/res-9"
cat > "$TESTDIR/src/actpkg-1.0/hard.txt" <<'EOF2'
execl("/bin/sh", "sh", "-c", cmd);
args = ["/bin/sh", "-c"]
MARKER a.b [x] $y & \z
version = 0.0.0
EOF2
printf 'one\n' > "$TESTDIR/src/actpkg-1.0/sub/deep/Makefile.in"
printf 'one\n' > "$TESTDIR/src/actpkg-1.0/sub/Makefile.in"
printf 'r\n' > "$TESTDIR/src/actpkg-1.0/res-9/file"
sha=$(tarball actpkg-1.0)
mkstar actpkg <<EOF2
load("//build_systems/lib.star", "replace_bin_sh")
package()
version("1.0", sha256 = "$sha", url = "http://example.invalid/actpkg-1.0.tar.gz")
build_system("generic")
depends_on("dash")

def setup_build_environment(ctx):
    return [setenv("ACT_A", "it's \$literal"), prepend_path("ACT_PATH", "/x"),
            prepend_path("ACT_PATH", "/y"), unsetenv("ACT_GONE")]

def edit(ctx):
    return [
        replace_bin_sh(ctx, "hard.txt"),
        substitute("hard.txt", "MARKER a.b [x] \$y & \\\\z", "edited & \\\\ | #"),
        filter_file("hard.txt", "^version = .*\$", "version = " + ctx.version),
        filter_file("sub/**/Makefile.in", "^one\$", "two"),
        move("res-*", "moved"),
    ]

def install(ctx):
    share = ctx.prefix + "/share"
    return [
        mkdir(share + "/d1", share + "/d2"),
        copy("hard.txt", share + "/hard.txt"),
        copy("sub", share + "/sub", recursive = True),
        copy("moved/file", share + "/moved"),
        write_file(share + "/tool", "#!" + ctx.sh + "\necho 'hi' \"\$1\"\n", mode = "755"),
        append_file(share + "/tool", "# appended\n"),
        symlink("tool", share + "/tool-link"),
        symlink("elsewhere", share + "/tool", if_missing = True),
        hardlink(share + "/tool", share + "/tool-hard"),
        run("sh", "-c", "echo \$ACT_A:\$ACT_PATH:\${ACT_GONE-unset}:\$RUNVAR:\$(pwd)",
            env = {"RUNVAR": "rv"}, cwd = share + "/d1", stdout = share + "/run.out"),
        sh("echo piped | tr a-z A-Z > '" + share + "/sh.out'"),
        chdir(share + "/d2"),
        run("touch", "here"),
        remove(share + "/d1", recursive = True),
        chmod("600", share + "/moved"),
    ]
EOF2

shpack install mkpkg atpkg ootpkg actpkg > "$TESTDIR/install.log" 2>&1 \
    || { cat "$TESTDIR/install.log"; fail "install failed"; }

S=$TESTDIR/store
mh=$(index_field mkpkg 3); ah=$(index_field atpkg 3); oh=$(index_field ootpkg 3)
assert_eq "$(cat "$S/mkpkg-1.0-$mh/share/data.out")" fixed "patched + makefile-built content"

out=$S/atpkg-2.0-$ah/share/out.txt
assert_contains "$out" "--prefix=$S/atpkg-2.0-$ah"
assert_contains "$out" "--disable-nls"
assert_contains "$out" "CXXCPP=tcc -E"
assert_contains "$out" "CONFIG_SHELL=$TEST_DASH_SH"
assert_contains "$S/atpkg-2.0-$ah/.shpack/build.sh" "make SHELL=$TEST_DASH_SH -j1"

oout=$S/ootpkg-1.0-$oh/share/out.txt
assert_contains "$oout" "/_build/sub"
assert_contains "$oout" "--prefix=$S/ootpkg-1.0-$oh"
assert_contains "$S/ootpkg-1.0-$oh/.shpack/build.sh" "../../configure"

# Starlark prefixes record the recipe and the executed plan
assert_file "$S/mkpkg-1.0-$mh/.shpack/package.star"
assert_file "$S/mkpkg-1.0-$mh/.shpack/build.sh"

# actions
xh=$(index_field actpkg 3)
X=$S/actpkg-1.0-$xh/share
assert_contains "$X/hard.txt" "execl(\"$TEST_DASH_SH\", \"sh\", \"-c\", cmd);"
assert_contains "$X/hard.txt" "[\"$TEST_DASH_SH\", \"-c\"]"
assert_contains "$X/hard.txt" 'edited & \ | #'
assert_contains "$X/hard.txt" "version = 1.0"
assert_eq "$(cat "$X/sub/Makefile.in")" two "** glob, top level"
assert_eq "$(cat "$X/sub/deep/Makefile.in")" two "** glob, nested"
assert_eq "$(cat "$X/moved")" r "glob move"
assert_eq "$("$X/tool" x)" "hi x" "write_file content and mode"
assert_contains "$X/tool" "# appended"
assert_eq "$(readlink "$X/tool-link")" tool "symlink"
assert_file "$X/tool-hard"
assert_eq "$(cat "$X/run.out")" "it's \$literal:/y:/x:unset:rv:$X/d1" "run env/cwd/stdout + persistent env"
assert_eq "$(cat "$X/sh.out")" PIPED "sh escape hatch"
assert_file "$X/d2/here"
[ ! -e "$X/d1" ] || fail "remove(recursive) left d1"

# per-version build system
shpack install bspkg@1.0 > "$TESTDIR/bs1.log" 2>&1 || { cat "$TESTDIR/bs1.log"; fail "bspkg@1.0"; }
assert_eq "$(cat "$S/bspkg-1.0-$(index_field bspkg 3)/share/data.out")" mk "makefile version"
shpack install bspkg@2.0 > "$TESTDIR/bs2.log" 2>&1 || { cat "$TESTDIR/bs2.log"; fail "bspkg@2.0"; }
assert_contains "$S/bspkg-2.0-$(index_field bspkg 3)/share/out.txt" "--prefix=$S/bspkg-2.0-"

# A plan-time error (a directive called from a phase) fails the build.
mkstar late <<'EOF2'
package()
version("1.0")
build_system("generic")
depends_on("dash")
def install(ctx):
    depends_on("liba")
    return []
EOF2
if shpack install late > "$TESTDIR/late.log" 2>&1; then
    fail "calling a directive from a phase must fail"
fi
grep -q "directives may only be called while the recipe loads" "$SHPACK_VAR/logs/late-1.0.log" \
    || { cat "$SHPACK_VAR/logs/late-1.0.log"; fail "late: wrong error"; }

echo OK
