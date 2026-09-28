# SPDX-License-Identifier: MIT
#
# repo.sh -- recipe loading.
#
# A package is a directory $REPO/<name> containing package.star (the recipe)
# plus optional patches/ and files/ subdirectories. Recipes are Starlark,
# evaluated by `star` (star/PROTOCOL.md): directive calls declare versions and
# their source checksums, dependencies, patches and the build system; phase
# functions return the actions that build the package.
#
# `star recipe` writes a recipe's directives into per-package state files under
# $VAR/recipe/<name>/, which concretization and the builder read:
#
#   versions         VER SHA FNAME URL      (first declared = default)
#   resources        WHEN SHA FNAME URL
#   deps             WHEN SPEC
#   patches          FILE level=N [when=VER] [arch=ARCH]
#   build_system     WHEN NAME
#   parallel         false
#   build_directory  DIR
#   description, homepage, license
#   loads            the //-modules the recipe loads, relative to the root
#
# '-' marks an absent field; WHEN is an exact version or '-' for all versions.
# The phases are evaluated at build time by `star plan` (builder.sh).

# recipe_load NAME -- capture NAME's directives into $VAR/recipe/NAME.
recipe_load() {
    RECIPE_STATE=$VAR/recipe/$1
    [ -f "$REPO/$1/package.star" ] || die "no recipe $REPO/$1/package.star"
    rm -rf "$RECIPE_STATE"
    mkdir -p "$RECIPE_STATE"
    "$STAR" recipe --repo "$REPO" --root "$STAR_ROOT" --out "$RECIPE_STATE" "$1" \
        || die "cannot load recipe $REPO/$1/package.star"
}

# recipe_meta NAME -- make sure NAME's directive state is loaded. Returns 1
# if there is no such recipe.
recipe_meta() {
    if [ -f "$VAR/recipe/$1/.loaded" ]; then return 0; fi
    if [ ! -f "$REPO/$1/package.star" ]; then return 1; fi
    recipe_load "$1"
    touch "$VAR/recipe/$1/.loaded"
}

# spec_sources NAME VER -> "SHA FNAME URL" lines for the version's main
# source plus all matching resources. Versions without sources print nothing.
spec_sources() {
    local rs v sha fname url when
    rs=$VAR/recipe/$1
    if [ -f "$rs/versions" ]; then
        while read -r v sha fname url; do
            if [ "$v" = "$2" ] && [ "$sha" != - ]; then
                printf '%s %s %s\n' "$sha" "$fname" "$url"
            fi
        done < "$rs/versions"
    fi
    if [ -f "$rs/resources" ]; then
        while read -r when sha fname url; do
            if [ "$when" = - ] || [ "$when" = "$2" ]; then
                printf '%s %s %s\n' "$sha" "$fname" "$url"
            fi
        done < "$rs/resources"
    fi
}
