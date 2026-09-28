# SPDX-License-Identifier: MIT
#
# concretize.sh -- resolve abstract specs to a concrete, hashed package DAG
# and emit the makefile that builds it.
#
# State produced under $VAR (fresh per concretization):
#   spec/<id>/        one dir per node, id = name-version
#     name, version, kind (built|external), hash, prefix
#     deps              direct dep ids, recipe order
#     edges             "ID TYPES" per direct dep, TYPES as in Spack (build,link,...)
#     closure           transitive dep ids, sorted
#     order             the closure in DFS post-order over declared deps
#     exec              what a dependent may run through this node: its run
#                       deps, and theirs and its link deps' (Spack's
#                       RUNTIME_EXECUTABLE); for a dependent's PATH
#     path              whose bin/ this node's build puts on PATH: every build
#                       dep, plus its exec
#     manifest          the canonical hash input (kept for auditability)
#   topo              all ids, dependencies before dependents
#   roots             ids of the requested packages
#   index             one line per node: NAME VERSION HASH KIND PREFIX
#   dag.mk            stamp-per-node makefile, scheduled by make

# resolve SPECSTR -- pick the node for "name" or "name@version".
# Candidates come from the recipe's declared versions and from the externals
# table (etc/externals: "name@version prefix" lines, the packages the kaem
# phase already installed; a relative prefix is under $STORE). Selection is
# first-match-wins: the newest version
# is simply the one declared first. Recipe versions have priority -- a recipe
# is the real definition, so for a bare name it always beats an external; the
# externals table is the fallback for names with no recipe (tcc, dash) and for
# explicit @version pins onto kaem seeds (musl@1.1.24, coreutils@5.0). An
# explicit @version must match the candidate string exactly.
# Sets: RES_ID RES_NAME RES_VERSION RES_KIND RES_PREFIX
resolve() {
    local name want best bestkind bestprefix ename eprefix v rest
    name=${1%%@*}
    want=
    case $1 in
        *@*) want=${1#*@} ;;
    esac
    best= bestkind= bestprefix=
    # Recipe first: first declared version (matching $want, if pinned) wins.
    if recipe_meta "$name" && [ -f "$VAR/recipe/$name/versions" ]; then
        while read -r v rest; do
            if [ -n "$want" ] && [ "$v" != "$want" ]; then continue; fi
            best=$v bestkind=built bestprefix=
            break
        done < "$VAR/recipe/$name/versions"
    fi
    # External fallback: only when no recipe version matched.
    if [ -z "$best" ] && [ -f "$EXTERNALS" ]; then
        while read -r ename eprefix; do
            case $ename in
                ''|'#'*) continue ;;
            esac
            if [ "${ename%%@*}" != "$name" ]; then continue; fi
            v=${ename#*@}
            if [ -n "$want" ] && [ "$v" != "$want" ]; then continue; fi
            case $eprefix in
                /*) ;;
                *) eprefix=$STORE/$eprefix ;;
            esac
            best=$v bestkind=external bestprefix=$eprefix
            break
        done < "$EXTERNALS"
    fi
    if [ -z "$best" ]; then
        die "cannot resolve '$1': no recipe or external version matches"
    fi
    RES_NAME=$name
    RES_VERSION=$best
    RES_KIND=$bestkind
    RES_PREFIX=$bestprefix
    RES_ID=$name-$best
}

# visit SPECSTR -- resolve one spec and recursively materialize its node and
# everything below it. Appends to $VAR/topo in dependency order. Sets
# VISIT_ID to the resolved id.
visit() {
    local id sdir name version kind prefix dep depid hash f c when types
    resolve "$1"
    id=$RES_ID name=$RES_NAME version=$RES_VERSION
    kind=$RES_KIND prefix=$RES_PREFIX
    sdir=$VAR/spec/$id
    if [ -f "$sdir/hash" ]; then
        VISIT_ID=$id
        return 0
    fi
    if [ -d "$sdir" ]; then
        die "dependency cycle through $id"
    fi
    mkdir -p "$sdir"
    printf '%s\n' "$name"    > "$sdir/name"
    printf '%s\n' "$version" > "$sdir/version"
    printf '%s\n' "$kind"    > "$sdir/kind"
    : > "$sdir/deps"
    : > "$sdir/edges"
    : > "$sdir/closure"
    : > "$sdir/order"
    : > "$sdir/exec"
    : > "$sdir/path"

    if [ "$kind" = external ]; then
        # Externals contribute their identity to dependents' hashes but have
        # no recipe content of their own. Identity is name+version only: the
        # absolute prefix is a deployment detail (it differs between store
        # roots, e.g. /opt under run-rootfs.sh vs $PWD/store for run-local.sh),
        # and baking it in would make every downstream hash depend on where the
        # store happens to live -- breaking relocation-invariance.
        printf 'external %s %s\n' "$name" "$version" \
            > "$sdir/manifest"
    else
        # Children first: their hashes feed this node's manifest. A dep with
        # a when= (the first field: versions, comma separated) is taken only
        # for a matching version of this node; '-' means all versions.
        if [ -f "$VAR/recipe/$name/deps" ]; then
            : > "$sdir/closure.tmp"     # when= may leave no dep at all
            while read -r when types dep; do
                when_matches "$when" "$version" || continue
                visit "$dep"
                depid=$VISIT_ID
                printf '%s\n' "$depid" >> "$sdir/deps"
                printf '%s %s\n' "$depid" "$types" >> "$sdir/edges"
                printf '%s\n' "$depid" >> "$sdir/closure.tmp"
                cat "$VAR/spec/$depid/closure" >> "$sdir/closure.tmp"
                # order: the closure in DFS post-order over declared deps
                # (dependencies before dependents), for compose_path.
                for c in $(cat "$VAR/spec/$depid/order") "$depid"; do
                    member_line "$c" "$sdir/order" || printf '%s\n' "$c" >> "$sdir/order"
                done
                # What goes on PATH, as Spack decides it: a build dep, and
                # what it runs -- its run deps, through run and link edges.
                case ,$types, in
                    *,run,*) add_line "$depid" "$sdir/exec" ;;
                esac
                case ,$types, in
                    *,run,*|*,link,*)
                        for c in $(cat "$VAR/spec/$depid/exec"); do
                            add_line "$c" "$sdir/exec"
                        done ;;
                esac
                case ,$types, in
                    *,build,*|*,test,*)
                        for c in "$depid" $(cat "$VAR/spec/$depid/exec"); do
                            add_line "$c" "$sdir/path"
                        done ;;
                esac
            done < "$VAR/recipe/$name/deps"
            sort -u "$sdir/closure.tmp" > "$sdir/closure"
            rm -f "$sdir/closure.tmp"
        fi
        # The evaluator identity ("star 1.0") enters the hash of every
        # Starlark recipe; ask for it once per concretization.
        if [ -f "$VAR/recipe/$name/loads" ] && [ -z "${STAR_VERSION:-}" ]; then
            STAR_VERSION=$("$STAR" version) || die "cannot run $STAR"
        fi
        {
            printf 'package %s\n' "$name"
            printf 'version %s\n' "$version"
            printf 'arch %s\n' "$ARCH"
            spec_sources "$name" "$version" | while read -r hash f dep; do
                printf 'source %s %s\n' "$hash" "$f"
            done
            for f in $(walk_files "$REPO/$name"); do
                printf 'file %s %s\n' "$(sha256_file "$REPO/$name/$f")" "$f"
            done
            # A Starlark recipe also depends on the evaluator and on every
            # module it loads (build systems, helpers), by content.
            if [ -f "$VAR/recipe/$name/loads" ]; then
                printf 'evaluator %s\n' "$STAR_VERSION"
                while read -r f; do
                    printf 'load %s %s\n' "$(sha256_file "$STAR_ROOT/$f")" "$f"
                done < "$VAR/recipe/$name/loads"
            fi
            while read -r dep types; do
                printf 'dep %s %s %s %s\n' \
                    "$(cat "$VAR/spec/$dep/name")" \
                    "$(cat "$VAR/spec/$dep/version")" \
                    "$(cat "$VAR/spec/$dep/hash")" "$types"
            done < "$sdir/edges" | sort
        } > "$sdir/manifest"
    fi

    hash=$(truncate7 "$(sha256_file "$sdir/manifest")")
    printf '%s\n' "$hash" > "$sdir/hash"
    if [ "$kind" = external ]; then
        printf '%s\n' "$prefix" > "$sdir/prefix"
    else
        printf '%s\n' "$STORE/$id-$hash" > "$sdir/prefix"
    fi
    printf '%s\n' "$id" >> "$VAR/topo"
    VISIT_ID=$id
}

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

emit_index() {
    local id
    : > "$VAR/index"
    for id in $(cat "$VAR/topo"); do
        printf '%s %s %s %s %s\n' \
            "$(cat "$VAR/spec/$id/name")" \
            "$(cat "$VAR/spec/$id/version")" \
            "$(cat "$VAR/spec/$id/hash")" \
            "$(cat "$VAR/spec/$id/kind")" \
            "$(cat "$VAR/spec/$id/prefix")" >> "$VAR/index"
    done
}

# stamp_of ID -> the stamp filename (hash included: a re-concretization that
# changes a node's hash invalidates its stamp).
stamp_of() {
    printf '%s-%s\n' "$1" "$(cat "$VAR/spec/$1/hash")"
}

# emit_dagmk -- one stamp target per built node; direct built deps as
# prerequisites (make supplies transitivity); the recipe runs `shpack
# build-one` in its own process with the precomposed PATH, logging to one
# file per package so parallel output does not interleave. '+' marks the
# recipe recursive so MAKEFLAGS (jobserver) reaches inner makes. Compatible
# with make 3.82, the only scheduler alive at shell-phase start.
emit_dagmk() {
    local id dep prefix stamp pre wrap hash name version
    {
        printf '# Generated by shpack concretize. Do not edit.\n'
        printf 'SHELL := %s\n' "$CONFIG_SHELL"
        printf 'S := %s/stamps\n' "$VAR"
        printf 'L := %s/logs\n' "$VAR"
        printf 'BASEPATH := %s\n' "$BASEPATH"
        # Sandbox knobs: each build step is wrapped in $(SANDBOX), confined to
        # the store (read+exec), recipe tree + distfiles (read), and its own
        # prefix + scratch (write). Emitted only when configured, so an
        # unsandboxed dag.mk is unchanged.
        if [ -n "$SANDBOX" ]; then
            printf 'SANDBOX := %s\n' "$SANDBOX"
            printf 'STORE := %s\n' "$STORE"
            printf 'SHPACK := %s\n' "$SHPACK_ROOT"
            printf 'REPO := %s\n' "$REPO"
            printf 'DISTFILES := %s\n' "$DISTFILES"
            printf 'V := %s\n' "$VAR"
        fi
        printf '\n'
        printf '.PHONY: all\n'
        printf 'all:'
        for id in $(cat "$VAR/roots"); do
            if [ "$(cat "$VAR/spec/$id/kind")" = built ]; then
                printf ' $(S)/%s' "$(stamp_of "$id")"
            fi
        done
        printf '\n\n'
        for id in $(cat "$VAR/topo"); do
            if [ "$(cat "$VAR/spec/$id/kind")" != built ]; then continue; fi
            prefix=$(cat "$VAR/spec/$id/prefix")
            hash=$(cat "$VAR/spec/$id/hash")
            name=$(cat "$VAR/spec/$id/name")
            version=$(cat "$VAR/spec/$id/version")
            printf '$(S)/%s:' "$(stamp_of "$id")"
            for dep in $(cat "$VAR/spec/$id/deps"); do
                if [ "$(cat "$VAR/spec/$dep/kind")" = built ]; then
                    printf ' $(S)/%s' "$(stamp_of "$dep")"
                fi
            done
            printf '\n'
            # Sandbox needs the prefix to exist before it can grant write to it,
            # so create it ahead of the wrapped build-one (which mkdir -p's it
            # again, now permitted). $(V) grants the whole scratch (stage dir,
            # recipe/spec state, $VAR/home). The log redirect, touch and cp run
            # outside the wrapper, so logging is unaffected.
            pre= wrap=
            if [ -n "$SANDBOX" ]; then
                pre="mkdir -p $prefix; "
                wrap="\$(SANDBOX) --read \$(STORE) --read \$(SHPACK) --read \$(REPO) --read \$(DISTFILES) --write \$(V) --write $prefix -- "
            fi
            printf '\t+@%sPATH=%s$(BASEPATH) \\\n' "$pre" "$(compose_path "$id")"
            printf '\t  %s$(SHELL) %s/bin/shpack build-one %s >$(L)/%s.log 2>&1 \\\n' \
                "$wrap" "$SHPACK_ROOT" "$id" "$id"
            printf '\t  || { echo "!! %s FAILED, tail of $(L)/%s.log:"; tail -n 40 $(L)/%s.log; exit 1; }\n' \
                "$id" "$id" "$id"
            printf '\t@test -f %s/.shpack/build.log || cp $(L)/%s.log %s/.shpack/build.log\n' \
                "$prefix" "$id" "$prefix"
            # Post-install marker (after build-one succeeds): one line per node,
            # Spack-style, so the prefix is copy-pasteable once it exists.
            printf '\t@echo "[+] %s %s@%s %s"\n' "$hash" "$name" "$version" "$prefix"
            printf '\t@touch $@\n\n'
        done
    } > "$VAR/dag.mk"
}

cmd_concretize() {
    local s
    if [ $# -lt 1 ]; then die "usage: shpack concretize <spec>..."; fi
    # Concretization itself runs on the base layer, independent of whatever
    # PATH the caller grew during the kaem phase.
    PATH=$BASEPATH
    export PATH
    rm -rf "$VAR/spec" "$VAR/recipe"
    rm -f "$VAR/topo" "$VAR/roots" "$VAR/index" "$VAR/dag.mk"
    mkdir -p "$VAR/spec" "$VAR/recipe"
    : > "$VAR/topo"
    : > "$VAR/roots"
    for s in "$@"; do
        visit "$s"
        printf '%s\n' "$VISIT_ID" >> "$VAR/roots"
    done
    emit_index
    emit_dagmk
    tree_print
    printf 'concretized %s node(s); makefile at %s\n' \
        "$(wc -l < "$VAR/topo" | tr -d ' ')" "$VAR/dag.mk"
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

# tree_line ID INDENT TYPES -- print one tree row: the node's hash in a fixed
# left column (hashes are 7 chars, so they align), the types of the edge that
# reached it as Spack prints them ([bl  ]: build, link, run, test), then
# INDENT and "name@version" (with " (external)" on kaem-phase nodes).
tree_line() {
    local n v h k tag t
    n=$(cat "$VAR/spec/$1/name")
    v=$(cat "$VAR/spec/$1/version")
    h=$(cat "$VAR/spec/$1/hash")
    k=$(cat "$VAR/spec/$1/kind")
    if [ "$k" = external ]; then tag=' (external)'; else tag=''; fi
    t=
    case ,$3, in *,build,*) t=${t}b ;; *) t="$t " ;; esac
    case ,$3, in *,link,*) t=${t}l ;; *) t="$t " ;; esac
    case ,$3, in *,run,*) t=${t}r ;; *) t="$t " ;; esac
    case ,$3, in *,test,*) t=${t}t ;; *) t="$t " ;; esac
    printf '%s  [%s]  %s%s@%s%s\n' "$h" "$t" "$2" "$n" "$v" "$tag"
}

# tree_print -- render the already-concretized DAG (on disk under $VAR: the
# roots list and per-node spec dirs) as an indented tree by iterative
# (recursion-free) depth-first traversal: each child is nested under its
# parent, two spaces per level. Each node is printed exactly once, the first
# time it is reached; a shared node already shown under an earlier parent is
# skipped (not reprinted, not re-descended). The frontier is an explicit
# stack held in one string, each frame a `<indent><TAB><types><TAB><id>` line
# (types: of the edge that pushed it, '-' for a root); we pop the
# front and prepend a node's children so they are visited before its
# siblings. Pure read -- no recomputation, no arithmetic, within the budget.
tree_print() {
    local id dep types stack rest frame indent cindent seen kids NL TAB
    NL='
'
    TAB=$(printf '\t')
    # Seed the stack with the roots, in order (empty indent).
    stack=''
    for id in $(cat "$VAR/roots"); do
        stack="$stack$TAB-$TAB$id$NL"
    done
    seen=' '
    while [ -n "$stack" ]; do
        frame=${stack%%"$NL"*}      # front frame
        rest=${stack#*"$NL"}        # everything below it
        indent=${frame%%"$TAB"*}
        frame=${frame#*"$TAB"}
        types=${frame%%"$TAB"*}
        id=${frame#*"$TAB"}
        case $seen in
            *" $id "*)
                # Already printed under an earlier parent: each node once.
                stack=$rest
                continue
                ;;
        esac
        seen="$seen$id "
        tree_line "$id" "$indent" "$types"
        # Prepend children (recipe order) so DFS descends before siblings.
        cindent="$indent  "
        kids=''
        while read -r dep types; do
            kids="$kids$cindent$TAB$types$TAB$dep$NL"
        done < "$VAR/spec/$id/edges"
        stack="$kids$rest"
    done
}
