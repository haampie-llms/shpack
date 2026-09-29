# SPDX-License-Identifier: MIT
#
# builder.sh -- build one concretized node in its own process.
#
# Invoked from a dag.mk recipe as `shpack build-one <id>` with PATH already
# composed from the node's dependency closure. The pipeline is:
#
#   fetch    verify (and if curl exists, download) the distfiles
#   stage    unpack into $VAR/stage/<id>, cd into the source directory
#   patch    apply the recipe's declared patches
#   plan     `star plan` evaluates the recipe's phases against this node's
#            build context and renders the actions as $SPEC/build.sh
#   <phases> source $SPEC/build.sh in this shell
#   finalize write $PREFIX/.spack, Spack's metadata: spec.json, the recipe,
#            and shpack's manifest and plan

# prefix_of NAME -> the store prefix of a dependency (direct or transitive).
prefix_of() {
    local d
    for d in $(cat "$SPEC/deps") $(cat "$SPEC/closure"); do
        if [ "$(cat "$VAR/spec/$d/name")" = "$1" ]; then
            cat "$VAR/spec/$d/prefix"
            return 0
        fi
    done
    die "prefix_of: '$1' is not in the dependency closure of $id"
}

# direct_dep NAME -> true if NAME is a *direct* dependency of this recipe.
# Deliberately deps-only, not the full closure (unlike prefix_of): it decides
# $sh, which must reflect what the recipe itself declared. glibc depends on the
# clean dash and almost everything sits on glibc, so a closure check would be
# true nearly everywhere and pick a dash the recipe never asked for.
direct_dep() {
    local d
    for d in $(cat "$SPEC/deps"); do
        if [ "$(cat "$VAR/spec/$d/name")" = "$1" ]; then return 0; fi
    done
    return 1
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
    for d in $(cat "$SPEC/deps") $(cat "$SPEC/closure"); do
        dn=$(cat "$VAR/spec/$d/name")
        case $seen in
            *" $dn "*) continue ;;
        esac
        seen="$seen$dn "
        printf '        %s: %s,\n' "$(star_str "$dn")" "$(star_str "$(cat "$VAR/spec/$d/prefix")")"
    done
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

do_finalize() {
    # Metadata as Spack keeps it, in .spack/: the recipe directory under
    # repos/<namespace>/packages/ (bootstrap, shpack/repo.yaml's), and shpack's
    # own hash input and plan (the build log is copied in by dag.mk, as
    # spack-build-out.txt).
    mkdir -p "$PREFIX/.spack/repos/bootstrap/packages"
    cp -R "$package_dir" "$PREFIX/.spack/repos/bootstrap/packages/$name"
    cp "$SPEC/manifest" "$PREFIX/.spack/shpack-manifest"
    cp "$SPEC/build.sh" "$PREFIX/.spack/shpack-build.sh"
    # Drop libtool .la archives (as Spack does): nothing in this store-prefix
    # world links via libtool, and they bake build-time paths / dependency
    # orderings that differ across builds. A glob, not find -- shpack core has no
    # find; these always land directly in lib/ (and lib64/).
    rm -f "$PREFIX"/lib/*.la "$PREFIX"/lib64/*.la
    # Modes are part of what a build produces, so fix them rather than inherit
    # the umask and whatever the tarballs carried: directories 755, files 644,
    # or 755 if executable at all (Spack's default install permissions too).
    chmod -R u=rwX,go=rX "$PREFIX"
    # .spack/spec.json last: it marks the prefix installed, for shpack and
    # Spack alike.
    cp "$SPEC/spack-spec.json" "$PREFIX/.spack/spec.json"
    cd /
    # SHPACK_KEEP_STAGE=1 keeps it, for comparing two builds of a package.
    [ -n "${SHPACK_KEEP_STAGE:-}" ] || rm -rf "$stage_dir"
}

# cmd_register_one -- a node the kaem phase installed (its recipe's
# kaem-steps): the prefix is there, so it only gets its metadata, as a build's
# finalize writes it; .spack/spec.json marks it installed.
cmd_register_one() {
    if [ $# -ne 1 ]; then die "usage: shpack register-one <id>"; fi
    id=$1
    SPEC=$VAR/spec/$id
    [ "$(cat "$SPEC/kind")" = kaem ] || die "node '$id' is not the kaem phase's"
    name=$(cat "$SPEC/name")
    PREFIX=$(cat "$SPEC/prefix")
    [ -d "$PREFIX" ] || die "$id: the kaem phase did not install $PREFIX"
    # Modes as a build's finalize leaves them (the kaem phase's follow the
    # umask, and the mescc-tools cp makes 0600 files).
    chmod -R u=rwX,go=rX "$PREFIX"
    mkdir -p "$PREFIX/.spack/repos/bootstrap/packages"
    rm -rf "$PREFIX/.spack/repos/bootstrap/packages/$name"
    cp -R "$REPO/$name" "$PREFIX/.spack/repos/bootstrap/packages/$name"
    cp "$SPEC/manifest" "$PREFIX/.spack/shpack-manifest"
    cp "$SPEC/spack-spec.json" "$PREFIX/.spack/spec.json"
    echo "==> $id: registered $PREFIX"
}

cmd_build_one() {
    if [ $# -ne 1 ]; then die "usage: shpack build-one <id>"; fi
    id=$1
    SPEC=$VAR/spec/$id
    [ -f "$SPEC/kind" ] || die "unknown node '$id' (run shpack concretize)"
    [ "$(cat "$SPEC/kind")" = built ] || die "node '$id' is external"
    name=$(cat "$SPEC/name")
    version=$(cat "$SPEC/version")
    hash=$(cat "$SPEC/hash")
    PREFIX=$(cat "$SPEC/prefix")
    if [ -f "$PREFIX/.spack/spec.json" ]; then
        echo "$id is already installed in $PREFIX"
        return 0
    fi

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
        HOME="$BUILD_HOME" SHELL sh PATH

    # Dirs the compiler-wrapper package injects as -I / -L / -Wl,-rpath, plus
    # PKG_CONFIG_PATH for configure. Direct link deps only: each shared lib
    # records its own DT_RUNPATH at build time, so transitive libs resolve
    # without the whole closure. Harmless for packages that don't use the
    # wrapper -- the SHPACK_* vars are read only by the wrapper shims.
    local depdir deptypes liblist p
    SHPACK_INCLUDE_DIRS= SHPACK_LINK_DIRS= SHPACK_RPATH_DIRS=
    PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}
    while read -r depdir deptypes; do
        case ,$deptypes, in
            *,link,*) ;;
            *) continue ;;
        esac
        p=$(cat "$VAR/spec/$depdir/prefix")
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
    # The environment the plan runs in, for the record (and for other hosts
    # of the same recipe to compare against).
    export -p > "$SPEC/env"
    . "$SPEC/build.sh"

    echo "==> $id: finalize"
    do_finalize
    echo "==> $id: installed in $PREFIX"
}
