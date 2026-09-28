# SPDX-License-Identifier: MIT
#
# concretize.sh -- `shpack concretize`, `spec`, `install`, `env` and `find`.
#
# Concretization itself is Starlark: lib/concretize.star, run by `star
# concretize`, resolves the specs and writes the node state under $VAR/spec,
# topo, roots, index and dag.mk (documented in concretize.star). This file
# hands it the configuration and runs the result.

# compose_path ID -> "ownbin:depbin:...:" -- the node's own bin dir, then the
# bin dir of every node in its path set (build deps and what they run, not
# link-only deps or the build deps of deps), most-derived first, each suffixed
# ':'. The caller appends BASEPATH. The order is the node's own (a DFS
# post-order over its declared dependencies, reversed), never the whole DAG's:
# which of two dependencies' `ld` comes first must not depend on what else was
# concretized alongside, since it is not in the hash.
compose_path() {
    local out c
    out=$(cat "$VAR/spec/$1/prefix")/bin:
    for c in $(reverse_lines "$VAR/spec/$1/order"); do
        member_line "$c" "$VAR/spec/$1/path" || continue
        out=$out$(cat "$VAR/spec/$c/prefix")/bin:
    done
    printf '%s' "$out"
}

# stamp_of ID -> the stamp filename (hash included: a re-concretization that
# changes a node's hash invalidates its stamp).
stamp_of() {
    printf '%s-%s\n' "$1" "$(cat "$VAR/spec/$1/hash")"
}

# write_concretize_cfg -- the configuration concretize.star reads, as a
# Starlark file (cfg = {...}).
write_concretize_cfg() {
    local k v
    printf 'cfg = {\n'
    for k in store arch var basepath config_shell sandbox shpack_root repo \
             distfiles star_root externals; do
        case $k in
            store) v=$STORE ;;  arch) v=$ARCH ;;  var) v=$VAR ;;
            basepath) v=$BASEPATH ;;  config_shell) v=$CONFIG_SHELL ;;
            sandbox) v=${SANDBOX:-} ;;  shpack_root) v=$SHPACK_ROOT ;;
            repo) v=$REPO ;;  distfiles) v=$DISTFILES ;;
            star_root) v=$STAR_ROOT ;;  externals) v=$EXTERNALS ;;
        esac
        printf '    "%s": %s,\n' "$k" "$(star_str "$v")"
    done
    printf '}\n'
}

cmd_concretize() {
    if [ $# -lt 1 ]; then die "usage: shpack concretize <spec>..."; fi
    # Concretization itself runs on the base layer, independent of whatever
    # PATH the caller grew during the kaem phase.
    PATH=$BASEPATH
    export PATH
    rm -rf "$VAR/spec" "$VAR/recipe"
    rm -f "$VAR/topo" "$VAR/roots" "$VAR/index" "$VAR/dag.mk"
    mkdir -p "$VAR/spec" "$VAR/recipe"
    write_concretize_cfg > "$VAR/concretize-cfg.star"
    "$STAR" concretize --repo "$REPO" --root "$STAR_ROOT" \
        --module "$SHPACK_LIB/concretize.star" --cfg "$VAR/concretize-cfg.star" \
        --out "$VAR" "$@" || die "concretization failed"
}

# cmd_spec -- concretize the given specs and show the resulting DAG as a
# tree. The tree is already printed by cmd_concretize (from on-disk node
# data, no recomputation); spec is the human-facing name for that view.
cmd_spec() {
    if [ $# -lt 1 ]; then die "usage: shpack spec <spec>..."; fi
    cmd_concretize "$@"
}

# cmd_install -- concretize, then schedule. Two stages when the DAG itself
# contains the parallel-safe make (config: SHPACK_BOOTSTRAP_MAKE, e.g.
# gmake@4.4.1): first build that node serially under the bootstrap-era make
# already on BASEPATH (whose -j is not trusted), then run the full DAG -jN
# under the new one.
cmd_install() {
    local bid bprefix
    cmd_concretize "$@"
    mkdir -p "$VAR/stamps" "$VAR/logs"
    PATH=$BASEPATH
    export PATH
    # Keep every build's temp files inside its own scratch ($VAR), not the host
    # /tmp: tidier (cleaned with $VAR) and it puts the gmake jobserver FIFO --
    # created here by the top make, outside the sandbox -- somewhere the wrapped
    # inner makes can still open it ($VAR is sandbox-writable; /tmp is not).
    TMPDIR=$VAR
    export TMPDIR
    if [ -n "${SHPACK_BOOTSTRAP_MAKE:-}" ]; then
        bid=${SHPACK_BOOTSTRAP_MAKE%%@*}-${SHPACK_BOOTSTRAP_MAKE#*@}
        if [ -f "$VAR/spec/$bid/kind" ] \
            && [ "$(cat "$VAR/spec/$bid/kind")" = built ]; then
            make -f "$VAR/dag.mk" "$VAR/stamps/$(stamp_of "$bid")"
            bprefix=$(cat "$VAR/spec/$bid/prefix")
            PATH=$bprefix/bin:$PATH
            export PATH
        fi
    fi
    exec make -f "$VAR/dag.mk" -j"$JOBS" all
}

cmd_env() {
    local n v h k p found
    if [ $# -ne 1 ]; then die "usage: shpack env <name|id>"; fi
    [ -f "$VAR/index" ] || die "no concretized DAG (run shpack concretize)"
    found=
    while read -r n v h k p; do
        if [ "$n-$v" = "$1" ] || [ "$n" = "$1" ]; then
            found=$n-$v
            break
        fi
    done < "$VAR/index"
    [ -n "$found" ] || die "'$1' is not in the concretized DAG"
    printf 'PREFIX=%s\n' "$(cat "$VAR/spec/$found/prefix")"
    printf 'PATH=%s%s\n' "$(compose_path "$found")" "$BASEPATH"
}

cmd_find() {
    local n v h k p d
    if [ -f "$VAR/index" ]; then
        while read -r n v h k p; do
            printf '%-10s %s@%s  %s\n' "[$k]" "$n" "$v" "$p"
        done < "$VAR/index"
    else
        for d in "$STORE"/*; do
            if [ -f "$d/.shpack/spec" ]; then
                printf '%s\n' "$d"
            fi
        done
    fi
}
