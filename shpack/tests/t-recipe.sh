# SPDX-License-Identifier: MIT
# Recipes: the directive state star writes, when= conditions,
# the manifest lines for the evaluator and loaded modules, and recipe errors.

. "$(dirname "$0")/common.sh"

mkstar liba <<'EOF2'
"""toy leaf
   library"""
homepage = "https://example.invalid/liba"
license("MIT")
version("1.0")
build_system("generic")
depends_on("dash")
def install(ctx):
    return []
EOF2

mkstar libb <<'EOF2'
"""toy mid-layer, two versions"""
version("2.1")
version("2.0")
build_system("generic")
depends_on("liba")
depends_on("dash")
depends_on("cdep", when = "@=2.0")
def install(ctx):
    return []
EOF2

mkstar cdep <<'EOF2'
"""only libb@2.0 depends on me"""
version("1.0")
build_system("generic")
depends_on("dash")
def install(ctx):
    return []
EOF2

mkstar tool <<'EOF2'
"""toy root"""
version("0.5")
build_system("generic")
depends_on("libb@2.1")
depends_on("liba")
depends_on("ext")
depends_on("dash")
def install(ctx):
    return []
EOF2

echo "ext@3.0 /fake/ext-3.0" >> "$SHPACK_EXTERNALS"

shpack concretize tool > "$TESTDIR/c.log" 2>&1 || { cat "$TESTDIR/c.log"; fail "concretize failed"; }

assert_eq "$(index_field libb 2)" 2.1 "bare libb resolves to the first declared version"
assert_eq "$(index_field ext 4)" external "ext kind"
assert_eq "$(index_field liba 4)" built "liba kind"
# the state files lib/repo.sh documents
assert_eq "$(cat "$SHPACK_VAR/recipe/libb/versions")" "2.1 - - -
2.0 - - -" "versions state"
assert_contains "$SHPACK_VAR/recipe/libb/deps" "2.0 build,link cdep"
assert_contains "$SHPACK_VAR/recipe/libb/deps" "- build,link liba"
assert_eq "$(cat "$SHPACK_VAR/recipe/liba/description")" "toy leaf library" "description state"
assert_eq "$(cat "$SHPACK_VAR/recipe/liba/homepage")" "https://example.invalid/liba" "homepage state"
assert_eq "$(cat "$SHPACK_VAR/recipe/liba/license")" "- MIT" "license state"
# when="@=2.0" only applies to 2.0: 2.1 has no cdep
case $(cat "$SHPACK_VAR/topo") in
    *cdep*) fail "cdep must not be in libb@2.1's closure" ;;
esac
shpack concretize libb@2.0 > /dev/null
grep -q cdep "$SHPACK_VAR/spec/libb-2.0/deps" || fail "libb@2.0 must depend on cdep"

# The manifest of a Starlark recipe names the evaluator and hashes each
# module the recipe loads (here the generic build system).
m=$SHPACK_VAR/spec/liba-1.0/manifest
assert_contains "$m" "evaluator star 1.0"
assert_contains "$m" "load "
assert_contains "$m" " build_systems/generic.star"

# Hashes: deterministic, and Merkle-propagated.
shpack concretize tool > /dev/null
a1=$(index_field liba 3); b1=$(index_field libb 3); t1=$(index_field tool 3)
shpack concretize tool > /dev/null
assert_eq "$(index_field liba 3)" "$a1" "liba hash determinism"
assert_eq "$(index_field tool 3)" "$t1" "tool hash determinism"

echo "# tweak" >> "$SHPACK_REPO/liba/package.star"
shpack concretize tool > /dev/null
[ "$(index_field liba 3)" != "$a1" ] || fail "liba hash must change with its recipe"
[ "$(index_field libb 3)" != "$b1" ] || fail "libb hash must change with a dep"
[ "$(index_field tool 3)" != "$t1" ] || fail "tool hash must change transitively"

# Editing a loaded module changes the hash of every recipe that loads it.
a2=$(index_field liba 3)
echo "# tweak" >> "$SHPACK_STAR_ROOT/build_systems/generic.star"
shpack concretize tool > /dev/null
[ "$(index_field liba 3)" != "$a2" ] || fail "editing generic.star must change liba's hash"

# Recipe errors surface at concretization.
mkstar bad <<'EOF2'
version("1.0")
depends_on("dash", when = "@1.0")
EOF2
if shpack concretize bad > "$TESTDIR/bad.log" 2>&1; then
    fail "a version-range when= must be rejected"
fi
assert_contains "$TESTDIR/bad.log" "use @=VERSION"

# One spec per depends_on, and only Spack's dependency types.
mkstar bad <<'EOF2'
version("1.0")
depends_on("dash", "liba")
EOF2
if shpack concretize bad > "$TESTDIR/bad.log" 2>&1; then
    fail "depends_on with two specs must be rejected"
fi
mkstar bad <<'EOF2'
version("1.0")
depends_on("dash", type = "runtime")
EOF2
if shpack concretize bad > "$TESTDIR/bad.log" 2>&1; then
    fail "an unknown dependency type must be rejected"
fi
assert_contains "$TESTDIR/bad.log" "want build, link, run or test"

mkstar late <<'EOF2'
version("1.0")
build_system("generic")
depends_on("dash")
def install(ctx):
    depends_on("liba")
    return []
EOF2
# directives are fine at load time; calling one from a phase fails the plan
shpack concretize late > /dev/null || fail "late: concretize should succeed"

echo OK
