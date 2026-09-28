# SPDX-License-Identifier: MIT

"""GNU binutils 2.46.0, glibc-linked: the as/ld baked into the final GCC. Built
by gcc-boot-wrapper against glibc 2.43; the bootstrap stages are binutils-boot0
(2.30, musl) and binutils-boot1 (2.46.0, musl)."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.gnu.org/software/binutils/"
license("GPL-3.0-or-later")

version(
    "2.46.0",
    sha256 = "0f3152632a2a9ce066f20963e9bb40af7cf85b9b6c409ed892fd0676e84ecd12",
    url = "https://ftp.gnu.org/gnu/binutils/binutils-2.46.0.tar.bz2",
)

build_system("autotools")

# linux-headers: autoconf CPP sanity check. libstdcxx-boot1: gprofng is C++ and
# links libstdc++.a.
depends_on("gcc-boot-wrapper", type = "build")
depends_on("glibc")
depends_on("linux-headers")
depends_on("libstdcxx-boot1")
depends_on("binutils-boot1", type = "build")
depends_on("zlib-ng@2.3.3-boot")
depends_on("zstd@1.5.7-boot")
depends_on("bison", type = "build")
depends_on("gmake", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("findutils", type = "build")
depends_on("dash", type = "build")

def setup_build_environment(ctx):
    # glibc headers/libs for the wrapped boot compiler. gprofng is C++ but
    # gcc-boot2 was --disable-libstdc++-v3, so supply libstdcxx-boot1's C++
    # headers (the triple subdir has bits/c++config.h).
    glibc = ctx.dep("glibc").prefix
    libstdcxx = ctx.dep("libstdcxx-boot1").prefix
    zlib = ctx.dep("zlib-ng").prefix
    zstd = ctx.dep("zstd").prefix
    t = triple(ctx)
    return [
        # Generated parsers ship and no flex exists; preseed to short-circuit
        # AC_PROG_LEX, which would otherwise fatally run $LEX.
        setenv("ac_cv_prog_lex_root", "lex.yy"),
        setenv("C_INCLUDE_PATH", ":".join([glibc + "/include", zlib + "/include", zstd + "/include"])),
        setenv("CPLUS_INCLUDE_PATH", ":".join([
            libstdcxx + "/include", libstdcxx + "/include/" + t, glibc + "/include",
            zlib + "/include", zstd + "/include",
        ])),
        setenv("LIBRARY_PATH", ":".join([glibc + "/lib", zlib + "/lib", zstd + "/lib"])),
    ]

def configure_args(ctx):
    t = triple(ctx)
    gcc = ctx.dep("gcc-boot-wrapper").prefix
    libstdcxx = ctx.dep("libstdcxx-boot1").prefix
    zstd = ctx.dep("zstd").prefix
    return [
        # native build, 64-bit BFD, reproducible archives, no NLS/werror
        "MAKEINFO=true",
        "--build=" + t,
        "--host=" + t,
        "--target=" + t,
        "--enable-64-bit-bfd",
        "--enable-deterministic-archives",
        "--disable-nls",
        "--disable-werror",
        # gprofng links static libstdcxx-boot1. Link the static, glibc-linked
        # zlib-ng/zstd (no .so in those prefixes -> static link) and default to
        # compressing debug sections with zlib.
        "CC=" + gcc + "/bin/gcc",
        "CXX=" + gcc + "/bin/g++",
        "CFLAGS=-g -O2 " + ctx.file_prefix_map,
        "CXXFLAGS=-g -O2 " + ctx.file_prefix_map,
        "LDFLAGS=-L%s/lib64 -L%s/lib" % (libstdcxx, libstdcxx),
        "AR=ar",
        "AS=as",
        "NM=nm",
        "RANLIB=ranlib",
        "OBJCOPY=objcopy",
        "OBJDUMP=objdump",
        "READELF=readelf",
        "STRIP=strip",
        "--disable-gprofng",
        "--disable-multilib",
        "--with-system-zlib",
        "--with-zstd-include=" + zstd + "/include",
        "--with-zstd-lib=" + zstd + "/lib",
        "--enable-compressed-debug-sections=all",
        "--enable-default-compressed-debug-sections-algorithm=zlib",
    ]

def build_args(ctx):
    return ["MAKEINFO=true"]

def install(ctx):
    return [run("make", "install", "MAKEINFO=true")]
