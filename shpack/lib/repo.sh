# SPDX-License-Identifier: MIT
#
# repo.sh -- recipe state.
#
# A package is a directory $REPO/<name> containing package.star (the recipe)
# plus optional patches/ and files/ subdirectories. Recipes are Starlark,
# evaluated by `star` (star/PROTOCOL.md): directive calls declare versions and
# their source checksums, dependencies, patches and the build system; phase
# functions return the actions that build the package.
#
# `star` writes a recipe's directives into per-package state files under
# $VAR/recipe/<name>/ as concretization loads it (`star recipe --out` writes
# the same), and the builder reads them:
#
#   versions         VER SHA FNAME URL      (first declared = default)
#   resources        WHEN SHA FNAME URL
#   deps             WHEN TYPES SPEC        (TYPES: build,link,run,test subset)
#   patches          FILE level=N [when=VERS] [arch=ARCH]
#   license          WHEN ID
#   parallel         false                  (the recipe's `parallel = False`)
#   build_directory  DIR                    (its `build_directory = "..."`)
#   description      the docstring;  homepage  its `homepage = "..."`
#   loads            the //-modules the recipe loads, relative to the root
#
# '-' marks an absent field; WHEN is the versions of a when="@=V1,=V2", comma
# separated, or '-' for all versions (when_matches in spec.sh). The build
# system and the phases are evaluated at build time by `star plan` (builder.sh).

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
            if when_matches "$when" "$2"; then
                printf '%s %s %s\n' "$sha" "$fname" "$url"
            fi
        done < "$rs/resources"
    fi
}
