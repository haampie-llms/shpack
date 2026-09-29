# SPDX-License-Identifier: MIT
#
# builder.sh -- build one concretized node, for any host.
#
# The kaem phase installs this file with bin/shpack-build as the package
# shpack-builder (shpack/bootstrap/shpack-builder-1.0), which every DAG reaches
# through dash-boot: shpack's dag.mk and Spack's adapter both build a node by
# running `sh $builder/bin/shpack-build ID` from the store, so there is one
# builder, and its content is in every hash. Its input is the node's state
# directory and its closure's (star/PROTOCOL.md, Hosts):
#
#   $SHPACK_VAR/spec/<id>/  for the node, and for every node of its closure
#     name, prefix, kind (built|kaem|external), edges ("ID TYPES", recipe order)
#     step              a kaem node's step (kaem-steps), "seed" for the seed
#   and for the node itself, what concretization takes from the recipe:
#     version, deps (direct ids), closure (sorted ids), sources, patches, parallel
#
# plus SHPACK_REPO, SHPACK_STAR_ROOT, DISTFILES, ARCH and JOBS in the
# environment. Everything else -- PATH, the build shell, star, patch-shebangs
# -- it derives from the DAG. The pipeline is:
#
#   compose  the build's environment from the DAG (compose_env)
#   fetch    verify (and if curl exists, download) the distfiles
#   stage    unpack into $VAR/stage/<id>, cd into the source directory
#   patch    apply the recipe's declared patches
#   plan     `star plan` evaluates the recipe's phases against this node's
#            build context and renders the actions as $SPEC/build.sh
#   <phases> source $SPEC/build.sh in this shell
#   finalize drop .la files, normalize modes; the plan goes to .spack/

# rd FILE -> the first line of FILE. A builtin read, not cat: the builder
# reads the DAG before it has composed a PATH.
rd() {
    local l
    l=
    read -r l < "$1" || [ -n "$l" ] || return 0
    printf '%s\n' "$l"
}

# prefix_of NAME -> the store prefix of a dependency (direct or transitive).
prefix_of() {
    local d
    while read -r d; do
        if [ "$(rd "$VAR/spec/$d/name")" = "$1" ]; then
            rd "$VAR/spec/$d/prefix"
            return 0
        fi
    done < "$SPEC/deps.all"
    die "prefix_of: '$1' is not in the dependency closure of $id"
}

# direct_dep NAME -> true if NAME is a *direct* dependency of this recipe.
# Deliberately deps-only, not the full closure (unlike prefix_of): it decides
# $sh, which must reflect what the recipe itself declared. glibc depends on the
# clean dash and almost everything sits on glibc, so a closure check would be
# true nearly everywhere and pick a dash the recipe never asked for.
direct_dep() {
    local d
    while read -r d; do
        if [ "$(rd "$VAR/spec/$d/name")" = "$1" ]; then return 0; fi
    done < "$SPEC/deps"
    return 1
}

# --- the environment, from the DAG ---------------------------------------
#
# Spack's rule (star/PROTOCOL.md, Hosts): a build runs its direct build (and
# test) dependencies, and what each of those runs -- its run dependencies,
# found through run and link edges. They go on PATH in the reverse of a DFS
# post-order over all declared edges, then the base: the kaem phase's PATH as
# it hands over to the shell phase, i.e. the kaem-phase nodes of the closure
# in that same order (every kaem step depends on the ones before it, so this
# is the chain, newest first) and the seed's PATH (bootstrap/seed.path).

# post_order ID -- append ID's dependencies to $ORDER (" ID ID ... "), each
# after its own dependencies, first visit wins.
post_order() {
    local d t
    while read -r d t; do
        case $ORDER in
            *" $d "*) continue ;;
        esac
        post_order "$d"
        ORDER="$ORDER$d "
    done < "$VAR/spec/$1/edges"
}

# runs ID -- add to $RUNS what a dependent may run through ID: its run
# dependencies, and what its run and link dependencies run.
runs() {
    local d t
    while read -r d t; do
        case ,$t, in
            *,run,*) RUNS="$RUNS$d " ;;
        esac
        case ,$t, in
            *,run,*|*,link,*) runs "$d" ;;
        esac
    done < "$VAR/spec/$1/edges"
}

# seed_path PREFIX -> bootstrap/seed.path's SEEDPATH, with ${SEED} as PREFIX.
seed_path() {
    local line out
    while read -r line; do
        case $line in
            SEEDPATH=*) line=${line#SEEDPATH=} ;;
            *) continue ;;
        esac
        out=
        while :; do
            case $line in
                *'${SEED}'*)
                    out=$out${line%%'${SEED}'*}$1
                    line=${line#*'${SEED}'} ;;
                *) break ;;
            esac
        done
        printf '%s\n' "$out$line"
        return 0
    done < "$STAR_ROOT/bootstrap/seed.path"
    die "seed.path has no SEEDPATH= line"
}

# compose_env -- PATH, CONFIG_SHELL, STAR and PATCH_SHEBANGS of this build.
# A host that has no kaem-phase nodes (the test fixture) passes the base as
# $BASEPATH and its tools as $CONFIG_SHELL, $STAR and $PATCH_SHEBANGS.
compose_env() {
    local d t c p kind path base seed
    ORDER=' '
    post_order "$id"
    RUNS=' '
    while read -r d t; do
        case ,$t, in
            *,build,*|*,test,*) RUNS="$RUNS$d "; runs "$d" ;;
        esac
    done < "$SPEC/edges"
    path= base= seed=
    for c in $ORDER; do
        p=$(rd "$VAR/spec/$c/prefix")
        case $RUNS in
            *" $c "*) path=$p/bin:$path ;;
        esac
        kind=$(rd "$VAR/spec/$c/kind")
        if [ "$kind" = kaem ]; then
            if [ "$(rd "$VAR/spec/$c/step")" = seed ]; then
                seed=$p
            else
                base=$p/bin:$base
            fi
        fi
    done
    if [ -n "$seed" ]; then
        base=$base$(seed_path "$seed")
        CONFIG_SHELL=$(prefix_of dash-boot)/bin/sh
        STAR=${STAR:-$(prefix_of star)/bin/star}
        PATCH_SHEBANGS=${PATCH_SHEBANGS-$(prefix_of patch-shebangs)/bin/patch-shebangs}
    else
        base=$BASEPATH
    fi
    PATH=$PREFIX/bin:$path$base
}

# --- the plan ------------------------------------------------------------
#
# A recipe does not run here: `star plan` evaluates its phases against a build
# context (ctx.star, written below) and renders the actions as a plain script
# ($SPEC/build.sh), which the builder sources in its own shell -- so cd and
# export persist from one phase to the next. The script calls only simple
# commands (through `command`) plus the two helpers below.

# star_sed SCRIPT FILE... -- sed -i on files that must exist (an unmatched glob
# stays literal and fails here, instead of silently editing nothing).
star_sed() {
    local script f
    script=$1
    shift
    [ $# -gt 0 ] || die "no file matched for $script"
    for f in "$@"; do
        [ -f "$f" ] || die "$f: no such file to edit"
    done
    sed -i "$script" "$@"
}

# star_rglob DIR PATTERN -> DIR/**/PATTERN: every file under DIR whose base
# name matches the glob PATTERN (walk_files, since there is no find).
star_rglob() {
    local f
    for f in $(walk_files "$1"); do
        case ${f##*/} in
            $2) printf '%s\n' "$1/$f" ;;
        esac
    done
}

# star_str S -> S as a Starlark string literal. Paths and names only: a
# quote or backslash is refused rather than escaped.
star_str() {
    case $1 in
        *'"'*|*'\'*) die "cannot pass '$1' to star (quote or backslash)" ;;
    esac
    printf '"%s"' "$1"
}

# write_ctx -- the build context of this node as a Starlark file (ctx.star).
write_ctx() {
    local k v d dn seen f first
    printf 'ctx = {\n'
    for k in name version id arch prefix sh stage_dir source_dir package_dir \
             file_prefix_map debug_prefix_map; do
        case $k in
            arch) eval "v=\$ARCH" ;;
            prefix) eval "v=\$PREFIX" ;;
            *) eval "v=\$$k" ;;
        esac
        printf '    "%s": %s,\n' "$k" "$(star_str "$v")"
    done
    printf '    "jobs": %s,\n' "$JOBS"
    if [ -n "$makejobs" ]; then
        printf '    "makejobs": [%s],\n' "$(star_str "$makejobs")"
    else
        printf '    "makejobs": [],\n'
    fi
    printf '    "package_files": ['
    first=1
    for f in $(walk_files "$package_dir"); do
        [ "$first" = 1 ] || printf ', '
        first=0
        star_str "$f"
    done
    printf '],\n'
    # name -> prefix over the direct deps then the closure, first one wins
    # (the prefix_of rule).
    printf '    "deps": {\n'
    seen=' '
    while read -r d; do
        dn=$(rd "$VAR/spec/$d/name")
        case $seen in
            *" $dn "*) continue ;;
        esac
        seen="$seen$dn "
        printf '        %s: %s,\n' "$(star_str "$dn")" "$(star_str "$(rd "$VAR/spec/$d/prefix")")"
    done < "$SPEC/deps.all"
    printf '    },\n'
    printf '}\n'
}

# download URL DEST -- best effort, mirrors first; only meaningful once curl
# exists (QEMU/network builds). The chroot bootstrap prestages distfiles.
download() {
    local m
    if ! command -v curl >/dev/null 2>&1; then
        die "distfile $2 is missing and there is no curl to fetch it"
    fi
    for m in ${MIRRORS:-}; do
        if curl --fail --retry 3 --location "$m/${2##*/}" --output "$2"; then
            return 0
        fi
    done
    if [ "$1" != - ]; then
        curl --fail --retry 3 --location "$1" --output "$2"
    fi
}

do_fetch() {
    local sha fname url
    while read -r sha fname url; do
        if [ ! -f "$DISTFILES/$fname" ]; then
            download "$url" "$DISTFILES/$fname"
        fi
        printf '%s  %s\n' "$sha" "$DISTFILES/$fname" > "$stage_dir/.fetch.sum"
        sha256sum -c "$stage_dir/.fetch.sum"
        rm -f "$stage_dir/.fetch.sum"
    done < "$SPEC/sources"
}

# unpack FILE -- extract an archive into the current directory. Compressors
# are piped so this works from the earliest bootstrap tar onward.
unpack() {
    case $1 in
        *.tar.gz|*.tgz)      gzip -dc "$1" | tar -xf - ;;
        *.tar.bz2)           bzip2 -dc "$1" | tar -xf - ;;
        *.tar.xz|*.tar.lzma) unxz < "$1" | tar -xf - ;;
        *.tar)               tar -xf "$1" ;;
        *)                   cp "$1" . ;;
    esac
}

do_stage() {
    local sha fname url d
    cd "$stage_dir"
    while read -r sha fname url; do
        unpack "$DISTFILES/$fname"
    done < "$SPEC/sources"
    # The source directory is the single directory the (first) tarball
    # created; sourceless packages build in the stage dir itself.
    source_dir=$stage_dir
    for d in *; do
        if [ -d "$d" ]; then
            source_dir=$stage_dir/$d
            break
        fi
    done
    cd "$source_dir"
}

# do_patch -- apply $SPEC/patches ("FILE LEVEL": the recipe's patches that
# apply to this version and arch, as concretization selected them).
do_patch() {
    local file level
    while read -r file level; do
        echo "==> $id: applying $file"
        command patch -p"$level" < "$package_dir/patches/$file"
    done < "$SPEC/patches"
}

# protocol_env -- a plan sees the environment star/PROTOCOL.md defines, and
# nothing of its host's or the builder's own (SHPACK_*, DISTFILES, ...: a
# Makefile reads its environment): everything else is un-exported, kept as a
# shell variable for the builder's helpers.
protocol_env() {
    local line name val
    export -p > "$VAR/exports.$$"
    while read -r line; do
        case $line in
            "export "*) ;;
            *) continue ;;   # the rest of a multi-line value
        esac
        name=${line#export }
        name=${name%%=*}
        case $name in
            PATH|PWD|CONFIG_SHELL|HOME|TMPDIR|TERM|PREFIX|ARCH|JOBS|makejobs|sh|SHELL|\
            MAKEFLAGS|MFLAGS|MAKELEVEL|SOURCE_DATE_EPOCH|PKG_CONFIG_PATH|\
            SHPACK_INCLUDE_DIRS|SHPACK_LINK_DIRS|SHPACK_RPATH_DIRS|SHPACK_FILE_PREFIX_MAP) ;;
            *[!A-Za-z0-9_]*|'') ;;
            *) eval "val=\${$name}"; unset "$name"; eval "$name=\$val" ;;
        esac
    done < "$VAR/exports.$$"
    rm -f "$VAR/exports.$$"
}

do_finalize() {
    # The plan (the build log is the host's).
    mkdir -p "$PREFIX/.spack"
    cp "$SPEC/build.sh" "$PREFIX/.spack/shpack-build.sh"
    # Drop libtool .la archives (as Spack does): nothing in this store-prefix
    # world links via libtool, and they bake build-time paths / dependency
    # orderings that differ across builds. A glob, not find -- shpack core has no
    # find; these always land directly in lib/ (and lib64/).
    rm -f "$PREFIX"/lib/*.la "$PREFIX"/lib64/*.la
    normalize_modes
    cd /
    # SHPACK_KEEP_STAGE=1 keeps it, for comparing two builds of a package.
    [ -n "${SHPACK_KEEP_STAGE:-}" ] || rm -rf "$stage_dir"
}

# normalize_modes -- modes are part of what an install produces, so fix them
# rather than inherit the umask and whatever the tarballs carried (the
# mescc-tools cp makes 0600 files): directories 755, files 644, or 755 if
# executable at all (Spack's default install permissions too). The kaem
# phase's prefixes get the same when they are registered.
normalize_modes() {
    chmod -R u=rwX,go=rX "$PREFIX"
}

build_node() {
    local d t depdir deptypes liblist p
    id=$1
    SPEC=$VAR/spec/$id
    [ -f "$SPEC/kind" ] || die "unknown node '$id'"
    [ "$(rd "$SPEC/kind")" = built ] || die "node '$id' is not built (external or kaem)"
    name=$(rd "$SPEC/name")
    version=$(rd "$SPEC/version")
    PREFIX=$(rd "$SPEC/prefix")

    # the direct deps then the closure: prefix_of's and ctx.deps' search order
    while read -r d; do printf '%s\n' "$d"; done < "$SPEC/deps" > "$SPEC/deps.all"
    while read -r d; do printf '%s\n' "$d"; done < "$SPEC/closure" >> "$SPEC/deps.all"

    compose_env
    export PATH

    package_dir=$REPO/$name

    # Empty so the inner make inherits the dag.mk jobserver from MAKEFLAGS;
    # an explicit -j would override it and oversubscribe JOBS x JOBS.
    # 'parallel false' needs -j1 to serialize against that jobserver.
    makejobs=
    if [ -f "$SPEC/parallel" ]; then
        makejobs=-j1
    fi
    # HOME under the build's own scratch ($VAR, itself under $TMPDIR on the
    # host): some configure/test steps write dotfiles, and a build must not
    # depend on or pollute a real home.
    BUILD_HOME=$VAR/home
    mkdir -p "$BUILD_HOME"
    # $sh, the build shell (configure/patch-shebangs/ctx.sh/SHELL=), is
    # the dash the recipe declares -- dash-boot (the kaem phase's) below the
    # glibc dash, the clean dash above it. Every built recipe must declare one:
    # the build always runs make/patch-shebangs, so there is no shell-free build,
    # and an explicit dep keeps the shell inside the node's recorded closure.
    if direct_dep dash; then
        sh=$(prefix_of dash)/bin/sh
    elif direct_dep dash-boot; then
        sh=$(prefix_of dash-boot)/bin/sh
    else
        die "$name declares no shell dependency (add depends_on(\"dash\") or \"dash-boot\")"
    fi
    SHELL=$sh
    # SHELL via MAKEFLAGS so it reaches recursive sub-makes and overrides even a
    # baked-in `SHELL = /bin/sh` (kernel headers, musl, gawk-boot); otherwise a
    # sub-make falls back to host /bin/sh, which the sandbox denies. Append to
    # preserve the dag.mk jobserver flags already here.
    MAKEFLAGS="${MAKEFLAGS:-} SHELL=$sh"
    export PREFIX ARCH JOBS makejobs MAKEFLAGS SOURCE_DATE_EPOCH=0 \
        HOME="$BUILD_HOME" TERM=dumb SHELL sh CONFIG_SHELL

    # Dirs the compiler-wrapper package injects as -I / -L / -Wl,-rpath, plus
    # PKG_CONFIG_PATH for configure. Direct link deps only: each shared lib
    # records its own DT_RUNPATH at build time, so transitive libs resolve
    # without the whole closure. Harmless for packages that don't use the
    # wrapper -- the SHPACK_* vars are read only by the wrapper shims.
    SHPACK_INCLUDE_DIRS= SHPACK_LINK_DIRS= SHPACK_RPATH_DIRS=
    PKG_CONFIG_PATH=
    while read -r depdir deptypes; do
        case ,$deptypes, in
            *,link,*) ;;
            *) continue ;;
        esac
        p=$(rd "$VAR/spec/$depdir/prefix")
        [ -d "$p/include" ] && \
            SHPACK_INCLUDE_DIRS=${SHPACK_INCLUDE_DIRS:+$SHPACK_INCLUDE_DIRS:}$p/include
        for liblist in "$p/lib64" "$p/lib"; do
            [ -d "$liblist" ] || continue
            SHPACK_LINK_DIRS=${SHPACK_LINK_DIRS:+$SHPACK_LINK_DIRS:}$liblist
            SHPACK_RPATH_DIRS=${SHPACK_RPATH_DIRS:+$SHPACK_RPATH_DIRS:}$liblist
            [ -d "$liblist/pkgconfig" ] && \
                PKG_CONFIG_PATH=${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$liblist/pkgconfig
        done
    done < "$SPEC/edges"
    export SHPACK_INCLUDE_DIRS SHPACK_LINK_DIRS SHPACK_RPATH_DIRS PKG_CONFIG_PATH

    stage_dir=$VAR/stage/$id
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    # Reproducibility: GCC (>=8) records the absolute build cwd as the DWARF
    # comp_dir and in __FILE__, so a debug build leaks the (scratch-dependent)
    # stage path into shipped libs. Recipes built by such a compiler append
    # $file_prefix_map to their CFLAGS/CXXFLAGS (and *_FOR_TARGET) to remap the
    # stage dir to a relative ".", making the bytes independent of build location
    # while keeping -g. tcc-built stages can't use it (no -ffile-prefix-map) and
    # instead drop -g. Inert when paths already match.
    #
    # $debug_prefix_map is the older -fdebug-prefix-map (DWARF only, no macro
    # __FILE__). It exists because glibc derives its assembler flags by filtering
    # CFLAGS for `-g% -fdebug-prefix-map=% -m%` (Makeconfig) -- it recognizes
    # -fdebug-prefix-map but NOT -ffile-prefix-map, so glibc's .S files (csu
    # crt*.o) need the debug-map form to keep their build path out of .debug_str.
    file_prefix_map="-ffile-prefix-map=$stage_dir=."
    debug_prefix_map="-fdebug-prefix-map=$stage_dir=."
    # The compiler-wrapper shims inject this into every real gcc/g++ call, so the
    # flag's stage-dependent value stays out of the build system (configure logs,
    # gcc -v) and app recipes need not append it by hand.
    export SHPACK_FILE_PREFIX_MAP="$file_prefix_map"

    echo "==> $id: fetch"
    do_fetch
    echo "==> $id: stage"
    do_stage
    do_patch

    # Repoint #!/bin/sh shebangs (build helpers like install-sh, config.guess are
    # exec'd directly) at the store shell, since the sandbox has no host /bin/sh.
    # Whole $stage_dir, not just $source_dir: a `resource` (gcc's in-tree gmp/
    # mpfr/mpc) sits as a sibling until the recipe's edit() relocates it.
    if [ -n "${PATCH_SHEBANGS:-}" ]; then
        echo "==> $id: patch-shebangs"
        "$PATCH_SHEBANGS" "$sh" "$stage_dir"
    fi

    write_ctx > "$SPEC/ctx.star"
    "$STAR" plan --repo "$REPO" --root "$STAR_ROOT" --ctx "$SPEC/ctx.star" \
        "$name" > "$SPEC/build.sh" || die "$name: star plan failed"
    mkdir -p "$PREFIX"
    protocol_env
    # The environment the plan runs in, for the record (and for other hosts
    # of the same recipe to compare against).
    export -p > "$SPEC/env"
    . "$SPEC/build.sh"

    echo "==> $id: finalize"
    do_finalize
    echo "==> $id: built in $PREFIX"
}
