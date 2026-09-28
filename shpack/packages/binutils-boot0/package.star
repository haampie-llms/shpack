# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "GNU binutils 2.30, built by tcc against musl: the bootstrap as/ld/ar "
                  + "for gcc 4.7 and 9.5 and the early musl tools. Stage 0 of three "
                  + "(binutils-boot1 is 2.46.0 for the musl world, binutils the final, "
                  + "glibc-linked 2.46.0).",
    homepage = "https://www.gnu.org/software/binutils/",
    license = "GPL-3.0-or-later",
)

version(
    "2.30-musl",
    sha256 = "8c3850195d1c093d290a716e20ebcaa72eda32abf5e3d8611154b39cff79e9ea",
    url = "https://ftp.gnu.org/gnu/binutils/binutils-2.30.tar.gz",
)

build_system("autotools")

# tcc + kaem-external musl 1.1.24 + m4; seed make/sed/tar suffice.
depends_on("tcc", "musl@1.1.24", "gmake", "grep@2.4-musl", "gawk@3.0.4", "diffutils", "m4")
depends_on("dash@0.5.12")

# The HOWTO table in bfd/elfnn-aarch64.c has #if/#else inside macro arguments,
# which tcc 0.9.26's preprocessor lineage cannot handle.
patch("arm64-elfnn-howto.patch", when = "target=aarch64:")

def setup_build_environment(ctx):
    return [
        # Generated parsers ship and no flex exists; preseed to short-circuit
        # AC_PROG_LEX, which would otherwise fatally run $LEX.
        setenv("ac_cv_prog_lex_root", "lex.yy"),
        # Cap libtool's command length so it never falls back to piecewise
        # archive linking (tcc -ar recreates the archive on each call, so
        # only the last batch would survive).
        setenv("lt_cv_sys_max_cmd_len", "131072"),
    ]

def configure_args(ctx):
    t = triple(ctx, "musl", vendor = "unknown")
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
        # tcc as compiler/linker/archiver against the musl sysroot
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

def build_args(ctx):
    return ["MAKEINFO=true", "M4=" + ctx.dep("m4").prefix + "/bin/m4"]

def install(ctx):
    return [run("make", "install", "MAKEINFO=true", "M4=" + ctx.dep("m4").prefix + "/bin/m4")]
