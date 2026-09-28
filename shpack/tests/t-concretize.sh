# SPDX-License-Identifier: MIT
# Concretization: resolution, externals, topo order, dag.mk shape.

. "$(dirname "$0")/common.sh"

mkstar liba <<'EOF'
"""toy leaf library"""
version("1.0")
build_system("generic")
def install(ctx):
    return []
EOF

mkstar libb <<'EOF'
"""toy mid-layer, two versions"""
version("2.1")
version("2.0")
build_system("generic")
depends_on("liba")
def install(ctx):
    return []
EOF

mkstar tool <<'EOF'
"""toy root"""
version("0.5")
build_system("generic")
depends_on("libb@2.1")
depends_on("liba")
depends_on("ext")
def install(ctx):
    return []
EOF

echo "ext@3.0 /fake/ext-3.0" > "$SHPACK_EXTERNALS"

shpack concretize tool > /dev/null

# Resolution: bare libb -> first declared (2.1); ext -> external with its prefix.
assert_eq "$(index_field libb 2)" 2.1 "libb version"
assert_eq "$(index_field ext 4)" external "ext kind"
assert_eq "$(index_field ext 5)" /fake/ext-3.0 "ext prefix"
assert_eq "$(index_field tool 4)" built "tool kind"

# Topo order: dependencies before dependents.
topo=$(cat "$SHPACK_VAR/topo" | tr '\n' ' ')
case $topo in
    *liba-1.0*libb-2.1*tool-0.5*) ;;
    *) fail "bad topo order: $topo" ;;
esac

# Built prefixes follow Spack's layout, {platform}-{target}/{name}-{version}-{hash}:
# the full (32 character) hash, whose first 7 the index shows.
h=$(index_field tool 3)
case $(index_field tool 5) in
    "$TESTDIR/store/linux-testarch/tool-0.5-$h"?????????????????????????) ;;
    *) fail "tool prefix: $(index_field tool 5)" ;;
esac

# dag.mk: tool's stamp depends on libb's and liba's but not on the external.
assert_contains "$SHPACK_VAR/dag.mk" "build-one tool-0.5"
case $(cat "$SHPACK_VAR/dag.mk") in
    *"/ext-"*"build-one ext"*) fail "external must not get a build rule" ;;
esac

# tool's composed PATH: own prefix first, then deps, then the external's bin.
sh "$TESTROOT/bin/shpack" env tool > "$TESTDIR/env.out"
assert_contains "$TESTDIR/env.out" "$(index_field tool 5)/bin:"
assert_contains "$TESTDIR/env.out" "/fake/ext-3.0/bin:"

# Pinned version resolves exactly.
shpack concretize libb@2.0 > /dev/null
assert_eq "$(index_field libb 2)" 2.0 "pinned libb version"

# Unknown packages and unknown deps fail loudly.
if shpack concretize nosuchpkg 2> /dev/null; then
    fail "expected concretize nosuchpkg to fail"
fi

mkstar broken <<'EOF'
version("1.0")
depends_on("missingdep")
EOF
if shpack concretize broken 2> /dev/null; then
    fail "expected unresolvable dep to fail"
fi

# Conditional (when=VER) dependencies: one recipe, two versions, dep sets
# differing by version, plus an unconditional dep shared by both.
mkstar dep-old <<'EOF'
version("1.0")
build_system("generic")
def install(ctx):
    return []
EOF
mkstar dep-new <<'EOF'
version("2.0")
build_system("generic")
def install(ctx):
    return []
EOF
mkstar multi <<'EOF'
version("4.7")
version("8.5")
build_system("generic")
depends_on("liba")
depends_on("dep-old", when = "@=4.7")
depends_on("dep-new", when = "@=8.5")
def install(ctx):
    return []
EOF

# @4.7 pulls dep-old and the unconditional liba, but not dep-new.
shpack concretize multi@4.7 > /dev/null
index_field dep-old 2 > /dev/null || fail "multi@4.7 must depend on dep-old"
index_field liba 2 > /dev/null    || fail "multi@4.7 must keep unconditional liba"
if index_field dep-new 2 > /dev/null; then
    fail "multi@4.7 must not pull dep-new (when=8.5)"
fi

# @8.5 is the mirror image.
shpack concretize multi@8.5 > /dev/null
index_field dep-new 2 > /dev/null || fail "multi@8.5 must depend on dep-new"
index_field liba 2 > /dev/null    || fail "multi@8.5 must keep unconditional liba"
if index_field dep-old 2 > /dev/null; then
    fail "multi@8.5 must not pull dep-old (when=4.7)"
fi

# when= takes a list of exact versions, as Spack's @=A,=B does.
mkstar multi2 <<'EOF'
version("4.7")
version("8.5")
version("9.0")
build_system("generic")
depends_on("dep-new", when = "@=8.5,=9.0")
def install(ctx):
    return []
EOF
shpack concretize multi2@9.0 > /dev/null
index_field dep-new 2 > /dev/null || fail "multi2@9.0 must depend on dep-new (@=8.5,=9.0)"
shpack concretize multi2@4.7 > /dev/null
if index_field dep-new 2 > /dev/null; then
    fail "multi2@4.7 must not pull dep-new (@=8.5,=9.0)"
fi

# Dependency types, as in Spack. A build's PATH has its build deps and what
# they run: their run deps, also through link deps. Not its link-only deps,
# and not the build deps of its deps.
for p in rt rt2 bh lk lk2; do
    mkstar $p <<EOF
version("1.0")
build_system("generic")
$(case $p in lk) echo 'depends_on("rt2", type = "run")' ;; esac)
def install(ctx):
    return []
EOF
done
mkstar tl <<'EOF'
version("1.0")
build_system("generic")
depends_on("rt", type = "run")
depends_on("bh", type = "build")
depends_on("lk")
def install(ctx):
    return []
EOF
mkstar top <<'EOF'
version("1.0")
build_system("generic")
depends_on("tl", type = "build")
depends_on("lk2", type = ("link",))
def install(ctx):
    return []
EOF
shpack concretize top > /dev/null
sh "$TESTROOT/bin/shpack" env top > "$TESTDIR/env.top"
for p in tl rt rt2; do
    assert_contains "$TESTDIR/env.top" "$(index_field $p 5)/bin:"
done
for p in bh lk lk2; do
    if grep -q "/$p-1.0-" "$TESTDIR/env.top"; then
        fail "$p must not be on top's PATH"
    fi
done
# ... while tl's own build sees its build dep, not its run-only dep (as in
# Spack: run deps are for its dependents).
sh "$TESTROOT/bin/shpack" env tl > "$TESTDIR/env.tl"
assert_contains "$TESTDIR/env.tl" "/bh-1.0-"
if grep -q "/rt-1.0-" "$TESTDIR/env.tl"; then
    fail "rt (run only) must not be on tl's own build PATH"
fi
# Everything is still built first, and the types are part of the hash.
assert_contains "$SHPACK_VAR/dag.mk" "build-one lk2-1.0"
assert_contains "$SHPACK_VAR/spec/top-1.0/manifest" "dep tl 1.0 $(index_field tl 3) build"
assert_contains "$SHPACK_VAR/spec/top-1.0/manifest" "dep lk2 1.0 $(index_field lk2 3) link"
h=$(index_field top 3)
sed 's/type = ("link",)/type = ("build", "link")/' "$SHPACK_REPO/top/package.star" > "$TESTDIR/top.star"
cp "$TESTDIR/top.star" "$SHPACK_REPO/top/package.star"
shpack concretize top > /dev/null
[ "$(index_field top 3)" != "$h" ] || fail "a dependency's type must be in the hash"
# `shpack spec` shows each edge's types the way `spack spec -t` does.
shpack spec top > "$TESTDIR/spec.top"
assert_contains "$TESTDIR/spec.top" "[b   ]    tl@1.0"
assert_contains "$TESTDIR/spec.top" "[  r ]      rt@1.0"
assert_contains "$TESTDIR/spec.top" "[bl  ]    lk2@1.0"

echo OK
