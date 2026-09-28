# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "GNU binutils. 2.46.0 is the glibc-linked as/ld baked into the "
                  + "final GCC; the -musl versions are the bootstrap as/ld used to "
                  + "build the musl-world chain (2.30 for gcc 4.7/9.5, 2.46.0-musl for "
                  + "the cap).",
    homepage = "https://www.gnu.org/software/binutils/",
    license = "GPL-3.0-or-later",
)

# The 2.46.0 source is built two ways under separate version strings (a node id
# is name-version): the glibc-linked as/ld baked into the final GCC, and a
# bootstrap-only musl as/ld. 2.30 is an older source for the early musl tools.

# 2.46.0: glibc-linked, built by gcc-boot-wrapper against glibc 2.43; gprofng
# links the static libstdcxx-boot1.
version(
    "2.46.0",
    sha256 = "0f3152632a2a9ce066f20963e9bb40af7cf85b9b6c409ed892fd0676e84ecd12",
    url = "https://ftp.gnu.org/gnu/binutils/binutils-2.46.0.tar.bz2",
)

# 2.46.0-musl: as/ld/ar built by the gcc-9.5 bridge in the musl world.
version(
    "2.46.0-musl",
    sha256 = "0f3152632a2a9ce066f20963e9bb40af7cf85b9b6c409ed892fd0676e84ecd12",
    url = "https://ftp.gnu.org/gnu/binutils/binutils-2.46.0.tar.bz2",
)

# 2.30-musl: the tcc-built early as/ld for gcc 4.7/9.5.
version(
    "2.30-musl",
    sha256 = "8c3850195d1c093d290a716e20ebcaa72eda32abf5e3d8611154b39cff79e9ea",
    url = "https://ftp.gnu.org/gnu/binutils/binutils-2.30.tar.gz",
)

build_system("autotools")

# 2.30-musl: tcc + kaem-external musl 1.1.24 + m4; seed make/sed/tar suffice.
depends_on(
    "tcc",
    "musl@1.1.24",
    "gmake",
    "grep@2.4-musl",
    "gawk@3.0.4",
    "diffutils",
    "m4",
    when = "@=2.30-musl",
)
# 2.46.0-musl: gcc 9.5, with 2.30-musl supplying the plain as/ld/ar. Modern
# sed/tar: 2.46's configure needs sed -E and its tarball is pax.
depends_on(
    "gcc-boot@9.5.0",
    "binutils@2.30-musl",
    "gmake",
    "grep@2.4-musl",
    "gawk@5.3.1",
    "diffutils",
    "sed@4.9-musl",
    "tar@1.35-musl",
    when = "@=2.46.0-musl",
)
# 2.46.0 (glibc): built by gcc-boot-wrapper against glibc 2.43. linux-headers:
# autoconf CPP sanity check. libstdcxx-boot1: gprofng is C++ and links libstdc++.a.
depends_on(
    "gcc-boot-wrapper",
    "glibc",
    "linux-headers",
    "libstdcxx-boot1",
    "binutils@2.46.0-musl",
    "zlib-ng@2.3.3-boot",
    "zstd@1.5.7-boot",
    "bison",
    "gmake",
    "sed@4.9-musl",
    "grep@2.4-musl",
    "gawk@5.3.1",
    "diffutils",
    "tar@1.35-musl",
    when = "@=2.46.0",
)

# Build shell: the bootstrap dash for the musl versions, the clean dash for 2.46.0.
depends_on("dash@0.5.12", when = "@=2.30-musl")
depends_on("dash@0.5.12", when = "@=2.46.0-musl")
depends_on("dash", when = "@=2.46.0")

# 2.30 only: the HOWTO table in bfd/elfnn-aarch64.c has #if/#else inside macro
# arguments, which tcc 0.9.26's preprocessor lineage cannot handle.
patch("arm64-elfnn-howto.patch", when = "@=2.30-musl target=aarch64:")

def setup_build_environment(ctx):
    # Generated parsers ship and no flex exists; preseed to short-circuit
    # AC_PROG_LEX, which would otherwise fatally run $LEX.
    env = [setenv("ac_cv_prog_lex_root", "lex.yy")]
    if ctx.satisfies("@=2.30-musl"):
        # Cap libtool's command length so it never falls back to piecewise
        # archive linking (tcc -ar recreates the archive on each call, so
        # only the last batch would survive).
        env.append(setenv("lt_cv_sys_max_cmd_len", "131072"))
    elif ctx.satisfies("@=2.46.0"):
        # glibc headers/libs for the wrapped boot0 compiler. gprofng is C++
        # but gcc-boot@16.1.0 was --disable-libstdc++-v3, so supply
        # libstdcxx-boot1's C++ headers (triple subdir has bits/c++config.h).
        glibc = ctx.dep("glibc").prefix
        libstdcxx = ctx.dep("libstdcxx-boot1").prefix
        zlib = ctx.dep("zlib-ng").prefix
        zstd = ctx.dep("zstd").prefix
        t = triple(ctx)
        env += [
            setenv("C_INCLUDE_PATH", ":".join([glibc + "/include", zlib + "/include", zstd + "/include"])),
            setenv("CPLUS_INCLUDE_PATH", ":".join([
                libstdcxx + "/include", libstdcxx + "/include/" + t, glibc + "/include",
                zlib + "/include", zstd + "/include",
            ])),
            setenv("LIBRARY_PATH", ":".join([glibc + "/lib", zlib + "/lib", zstd + "/lib"])),
        ]
    return env

# Shared base + per-version deltas. --prefix and --disable-dependency-tracking
# come from default_configure.
_TOOLS = [
    "AR=ar", "AS=as", "NM=nm", "RANLIB=ranlib",
    "OBJCOPY=objcopy", "OBJDUMP=objdump", "READELF=readelf", "STRIP=strip",
]

def configure_args(ctx):
    t = triple(ctx, "musl", vendor = "unknown") if ctx.satisfies("@=2.30-musl") else triple(ctx)
    # Common: native build, 64-bit BFD, reproducible archives, no NLS/werror.
    args = [
        "MAKEINFO=true",
        "--build=" + t,
        "--host=" + t,
        "--target=" + t,
        "--enable-64-bit-bfd",
        "--enable-deterministic-archives",
        "--disable-nls",
        "--disable-werror",
    ]
    if ctx.satisfies("@=2.30-musl"):
        # tcc as compiler/linker/archiver against the musl sysroot.
        return args + [
            "CC=tcc",
            "LD=tcc",
            "AR=tcc -ar",
            "RANLIB=true",
            "CFLAGS=-O2",
            "--with-sysroot=" + ctx.dep("musl").prefix,
            "--disable-dependency-tracking",
            "--disable-plugins",
            "--enable-static",
            "--disable-shared",
        ]
    if ctx.satisfies("@=2.46.0-musl"):
        # gcc 9.5 + the plain 2.30-musl tools; install libbfd, skip gprofng
        # (no C++/libstdc++ in the musl world yet).
        gcc = ctx.dep("gcc-boot").prefix
        return args + [
            "CC=" + gcc + "/bin/gcc",
            "CXX=" + gcc + "/bin/g++",
            "CFLAGS=-g -O2 " + ctx.file_prefix_map,
            "CXXFLAGS=-g -O2 " + ctx.file_prefix_map,
        ] + _TOOLS + [
            "--with-sysroot=/",
            "--enable-install-libbfd",
            "--disable-gprofng",
            "--enable-static",
            "--disable-shared",
        ]

    # 2.46.0: gcc-boot-wrapper against glibc; gprofng links static libstdcxx-boot1.
    # Link the static, glibc-linked zlib-ng/zstd (no .so in those prefixes
    # -> static link) and default to compressing debug sections with zlib.
    gcc = ctx.dep("gcc-boot-wrapper").prefix
    libstdcxx = ctx.dep("libstdcxx-boot1").prefix
    zstd = ctx.dep("zstd").prefix
    return args + [
        "CC=" + gcc + "/bin/gcc",
        "CXX=" + gcc + "/bin/g++",
        "CFLAGS=-g -O2 " + ctx.file_prefix_map,
        "CXXFLAGS=-g -O2 " + ctx.file_prefix_map,
        "LDFLAGS=-L%s/lib64 -L%s/lib" % (libstdcxx, libstdcxx),
    ] + _TOOLS + [
        "--disable-gprofng",
        "--disable-multilib",
        "--with-system-zlib",
        "--with-zstd-include=" + zstd + "/include",
        "--with-zstd-lib=" + zstd + "/lib",
        "--enable-compressed-debug-sections=all",
        "--enable-default-compressed-debug-sections-algorithm=zlib",
    ]

def build_args(ctx):
    return [
        "MAKEINFO=true",
        "case",
        ctx.version,
        "in",
        "2.30-musl)",
        "printf",
        "%s\\n",
        "M4=" + ctx.dep("m4").prefix + "/bin/m4",
        ";;",
        "esac",
    ]

def install(ctx):
    if ctx.satisfies("@=2.30-musl"):
        return [run("make", "install", "MAKEINFO=true", "M4=" + ctx.dep("m4").prefix + "/bin/m4")]
    actions = [run("make", "install", "MAKEINFO=true")]
    if ctx.satisfies("@=2.46.0-musl"):
        # Add <triple>-<tool> symlinks beside the plain names, which a native
        # build installs and AC_CHECK_TOOL looks for first under --host=<triple>.
        t = triple(ctx)
        actions.append(symlink_each(ctx.prefix + "/bin/*", ctx.prefix + "/bin", prefix = t + "-",
                                    relative = True, if_missing = True, exclude = t + "-*"))
    return actions
