# SPDX-License-Identifier: MIT
#
# install.sh -- `shpack build-one` and `register-one`, the dag.mk rules of a
# node: the build itself is the store's builder (lib/builder.sh, installed by
# the kaem phase as shpack-builder); what is shpack's own is the Spack
# metadata an install gets when shpack made it.

# write_metadata -- the end of every install, built or registered. Metadata
# as Spack keeps it, in .spack/: the recipe directory under
# repos/<namespace>/packages/ (bootstrap, shpack/repo.yaml's) and shpack's own
# hash input (a build's plan and log are copied in before this). Then modes
# (normalize_modes: a kaem-phase prefix has not had them fixed yet, and
# .spack/ is new). .spack/spec.json last: it marks the prefix installed, for
# shpack and Spack alike.
write_metadata() {
    mkdir -p "$PREFIX/.spack/repos/bootstrap/packages"
    rm -rf "$PREFIX/.spack/repos/bootstrap/packages/$name"
    cp -R "$REPO/$name" "$PREFIX/.spack/repos/bootstrap/packages/$name"
    cp "$SPEC/manifest" "$PREFIX/.spack/shpack-manifest"
    normalize_modes
    cp "$SPEC/spack-spec.json" "$PREFIX/.spack/spec.json"
}

# load_node ID KIND -- SPEC, id, name and PREFIX of a node of the given kind.
load_node() {
    id=$1
    SPEC=$VAR/spec/$id
    [ -f "$SPEC/kind" ] || die "unknown node '$id' (run shpack concretize)"
    [ "$(cat "$SPEC/kind")" = "$2" ] || die "node '$id' is not $2"
    name=$(cat "$SPEC/name")
    PREFIX=$(cat "$SPEC/prefix")
}

# cmd_register_one -- a node the kaem phase installed (its recipe's
# kaem-steps): the prefix is there, so it only gets its metadata, as a build's
# finalize writes it.
cmd_register_one() {
    if [ $# -ne 1 ]; then die "usage: shpack register-one <id>"; fi
    load_node "$1" kaem
    [ -d "$PREFIX" ] || die "$id: the kaem phase did not install $PREFIX"
    write_metadata
    echo "==> $id: registered $PREFIX"
}

# cmd_build_one -- build a node with the store's builder, unless its prefix is
# installed already, then record it.
cmd_build_one() {
    if [ $# -ne 1 ]; then die "usage: shpack build-one <id>"; fi
    load_node "$1" built
    if [ -f "$PREFIX/.spack/spec.json" ]; then
        echo "$id is already installed in $PREFIX"
        return 0
    fi
    "$CONFIG_SHELL" "$SHPACK_BUILDER" "$id"
    write_metadata
    echo "==> $id: installed in $PREFIX"
}
