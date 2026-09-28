# SPDX-License-Identifier: MIT

"""GNU binutils 2.46.0 for the musl world, built by gcc 9.5 with
binutils-boot0's plain as/ld/ar: the as/ld of gcc-boot2 and of glibc. Stage 1
of three (binutils is the final, glibc-linked 2.46.0)."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.gnu.org/software/binutils/"
license("GPL-3.0-or-later")

version(
    "2.46.0-musl",
    sha256 = "0f3152632a2a9ce066f20963e9bb40af7cf85b9b6c409ed892fd0676e84ecd12",
    url = "https://ftp.gnu.org/gnu/binutils/binutils-2.46.0.tar.bz2",
)

build_system("autotools")

# gcc 9.5, with binutils-boot0 supplying the plain as/ld/ar. Modern sed/tar:
# 2.46's configure needs sed -E and its tarball is pax.
depends_on("gcc-boot1", type = "build")
depends_on("binutils-boot0", type = "build")
depends_on("gmake", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("findutils", type = "build")
depends_on("dash@0.5.12", type = "build")

def setup_build_environment(ctx):
    # Generated parsers ship and no flex exists; preseed to short-circuit
    # AC_PROG_LEX, which would otherwise fatally run $LEX.
    return [setenv("ac_cv_prog_lex_root", "lex.yy")]

def configure_args(ctx):
    t = triple(ctx)
    gcc = ctx.dep("gcc-boot1").prefix
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
        # install libbfd, skip gprofng (no C++/libstdc++ in the musl world yet)
        "CC=" + gcc + "/bin/gcc",
        "CXX=" + gcc + "/bin/g++",
        "CFLAGS=-g -O2 " + ctx.file_prefix_map,
        "CXXFLAGS=-g -O2 " + ctx.file_prefix_map,
        "AR=ar",
        "AS=as",
        "NM=nm",
        "RANLIB=ranlib",
        "OBJCOPY=objcopy",
        "OBJDUMP=objdump",
        "READELF=readelf",
        "STRIP=strip",
        "--with-sysroot=/",
        "--enable-install-libbfd",
        "--disable-gprofng",
        "--enable-static",
        "--disable-shared",
    ]

def build_args(ctx):
    return ["MAKEINFO=true"]

def install(ctx):
    t = triple(ctx)
    return [
        run("make", "install", "MAKEINFO=true"),
        # Add <triple>-<tool> symlinks beside the plain names, which a native
        # build installs and AC_CHECK_TOOL looks for first under --host=<triple>.
        symlink_each(ctx.prefix + "/bin/*", ctx.prefix + "/bin", prefix = t + "-",
                     relative = True, if_missing = True, exclude = t + "-*"),
    ]
