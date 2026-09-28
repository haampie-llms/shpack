# SPDX-License-Identifier: MIT

"""Zstandard 1.5.7 -- a fast lossless compressor: the zstd CLI plus libzstd.
Built at the gcc-16 layer via the upstream Makefile."""

load("//build_systems/lib.star", "uname_shim")

homepage = "https://facebook.github.io/zstd/"
license("BSD-3-Clause OR GPL-2.0-or-later")

# GitHub source archive (extracts zstd-1.5.7/).
version(
    "1.5.7",
    sha256 = "37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3",
    url = "https://github.com/facebook/zstd/archive/v1.5.7.tar.gz",
    fname = "zstd-1.5.7.tar.gz",
)

# 1.5.7-boot: same source, but a static-only libzstd.a built in the toolchain
# layer (by gcc-boot-wrapper, against glibc) so gcc/binutils can link zstd
# statically -- no shared-lib resolution in the hot compiler path.
version(
    "1.5.7-boot",
    sha256 = "37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3",
    url = "https://github.com/facebook/zstd/archive/v1.5.7.tar.gz",
    fname = "zstd-1.5.7.tar.gz",
)

build_system("generic")

# 1.5.7: app-layer shared build via compiler-wrapper (final gcc 16).
# 1.5.7-boot: toolchain-layer static build by gcc-boot-wrapper.
depends_on("compiler-wrapper", when = "@=1.5.7", type = "build")
depends_on("gmake", when = "@=1.5.7", type = "build")
depends_on("gcc-boot-wrapper", when = "@=1.5.7-boot", type = "build")
depends_on("glibc", when = "@=1.5.7-boot")
depends_on("gmake", when = "@=1.5.7-boot", type = "build")
depends_on("sed@4.9-musl", when = "@=1.5.7-boot", type = "build")
depends_on("grep-boot", when = "@=1.5.7-boot", type = "build")
depends_on("gawk@5.3.1", when = "@=1.5.7-boot", type = "build")
depends_on("diffutils", when = "@=1.5.7-boot", type = "build")
depends_on("findutils", when = "@=1.5.7-boot", type = "build")
depends_on("tar@1.35-musl", when = "@=1.5.7-boot", type = "build")
depends_on("xz@5.2.5-musl", when = "@=1.5.7-boot", type = "build")
depends_on("sed@4.9-musl", when = "@=1.5.7", type = "build")
depends_on("grep-boot", when = "@=1.5.7", type = "build")
depends_on("gawk@5.3.1", when = "@=1.5.7", type = "build")
depends_on("diffutils", when = "@=1.5.7", type = "build")
depends_on("findutils", when = "@=1.5.7", type = "build")
depends_on("tar@1.35-musl", when = "@=1.5.7", type = "build")
depends_on("xz@5.2.5-musl", when = "@=1.5.7", type = "build")
depends_on("dash", type = "build")

def edit(ctx):
    # zstd's Makefiles do `$(shell uname)` to pick the shared-lib soname/flags;
    # uname is absent in the sandbox (see perl), so shim a minimal one to keep
    # libzstd.so's Linux soname.
    return uname_shim(ctx)

def install(ctx):
    if ctx.satisfies("@=1.5.7-boot"):
        # Library only, static only: no install-shared (no .so forces
        # static linking) and no CLI. Wrapper supplies glibc loader/libs
        # but not headers; add them.
        glibc = ctx.dep("glibc").prefix
        cc = ctx.dep("gcc-boot-wrapper").prefix + "/bin/gcc"
        return [
            setenv("C_INCLUDE_PATH", glibc + "/include"),
            setenv("LIBRARY_PATH", glibc + "/lib"),
            run("make", "-C", "lib", "SHELL=" + ctx.sh, "CC=" + cc, ctx.makejobs,
                "PREFIX=" + ctx.prefix, "install-pc", "install-includes", "install-static"),
        ]
    cc = ctx.dep("compiler-wrapper").prefix + "/bin/gcc"
    return [
        # Install the library (pkg-config, headers, static + shared) then the
        # zstd CLI. The optional zlib/lzma/lz4 backends are turned off
        # explicitly so the Makefile does not auto-detect and link them.
        run("make", "-C", "lib", "SHELL=" + ctx.sh, "CC=" + cc, ctx.makejobs,
            "PREFIX=" + ctx.prefix, "install-pc", "install-includes", "install-static",
            "install-shared"),
        run("make", "-C", "programs", "SHELL=" + ctx.sh, "CC=" + cc, ctx.makejobs,
            "PREFIX=" + ctx.prefix, "HAVE_ZLIB=0", "HAVE_LZMA=0", "HAVE_LZ4=0", "install"),
    ]
