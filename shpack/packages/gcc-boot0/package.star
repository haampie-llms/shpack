# SPDX-License-Identifier: MIT

"""GCC 4.7 (Linaro 2013.11), grown by tcc against musl 1.1.24: the first C/C++
compiler of the bootstrap (throwaway). Stage 0 of three: gcc-boot1 (9.5)
bridges to modern GCC, gcc-boot2 (16.1, crippled) compiles glibc; the shipped
GCC is packages/gcc."""

load("//build_systems/lib.star", "triple")

homepage = "https://gcc.gnu.org/"
license("GPL-3.0-or-later")

# Linaro snapshot: FSF 4.7 lacks native aarch64.
version(
    "4.7-2013.11",
    sha256 = "d0ea2c72ceb66d3851986840dd8962941824a2980a8aca2a800abb5b489acedf",
    url = "https://launchpadlibrarian.net/156843777/gcc-linaro-4.7-2013.11.tar.bz2",
)

build_system("autotools")

# GCC forbids an in-tree build; configure/build/install all happen in _build/.
build_directory = "_build"

# tcc against musl 1.1.24, external gmp/mpfr/mpc, binutils 2.30.
depends_on("gmake", type = "build")
depends_on("grep-boot", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tcc", type = "build")
depends_on("musl@1.1.24")
depends_on("binutils-boot0", type = ("build", "run"))
depends_on("gmp")
depends_on("mpfr")
depends_on("mpc")
depends_on("m4", type = "build")
depends_on("gawk-boot", type = "build")
depends_on("dash@0.5.12", type = "build")

# libiberty's C_alloca conflicts with musl's alloca; rename it (same fix as Guix).
patch("0001-alloca.patch")
# Work around a tcc 0.9.27 AArch64 spill-slot collision that miscompiles a nested
# struct-return call in set_lattice_value, crashing the tcc-built cc1 in tree-ccp.
# See bugs/tcc-aarch64-nested-struct-return-spill.md.
patch("0002-tree-ssa-ccp-spill.patch")
# os_defines.h uses __GLIBC_PREREQ(2,15), undefined on musl; guard it.
patch("0003-libstdcxx-musl-glibc-prereq.patch")
# gnu-linux ctype uses glibc-internal masks absent on musl; swap in the portable
# config/os/generic ctype (same as Alpine / musl-cross-make).
patch("0004-libstdcxx-generic-ctype.patch")

def edit(ctx):
    # Blank libgcc's hardcoded -g: 4.7's -fdebug-prefix-map misses the
    # include-fixed path it leaks into .debug_*, and a make-var override
    # can't reach the libgcc sub-make (gcc forwards only FLAGS_TO_PASS).
    return [filter_file("libgcc/Makefile.in", "^LIBGCC2_DEBUG_CFLAGS = -g$",
                        "LIBGCC2_DEBUG_CFLAGS =")]

def setup_build_environment(ctx):
    # edit() drops libgcc's -g; debug_prefix_map still covers any other
    # target debug. Env-passed to keep $stage_dir out of gcc 4.7's configargs.
    return [
        setenv("CFLAGS_FOR_TARGET", "-O2 " + ctx.debug_prefix_map),
        setenv("CXXFLAGS_FOR_TARGET", "-O2 " + ctx.debug_prefix_map),
    ]

# --prefix and --disable-dependency-tracking come from the autotools configure.
def configure_args(ctx):
    t = triple(ctx, "musl", vendor = "unknown")
    binutils = ctx.dep("binutils-boot0").prefix
    return [
        # native build, C/C++ only, static, no optional target libraries
        "MAKEINFO=true",
        "--build=" + t,
        "--host=" + t,
        "--target=" + t,
        "--enable-languages=c,c++",
        "--disable-shared",
        "--disable-bootstrap",
        "--disable-multilib",
        "--disable-decimal-float",
        "--disable-lto",
        "--disable-lto-plugin",
        "--disable-libatomic",
        "--disable-libgomp",
        "--disable-libitm",
        "--disable-libquadmath",
        "--disable-libsanitizer",
        "--disable-libssp",
        "--disable-libvtv",
        # tcc, external gmp/mpfr/mpc + musl sysroot. C only is built, but
        # configure still runs a fatal AC_PROG_CXXCPP probe; `tcc -E` satisfies
        # it (no C++ is actually compiled by the stage1 tools).
        "CC=tcc",
        "CC_FOR_BUILD=tcc",
        "CXX=tcc",
        "CXXCPP=tcc -E",
        "CFLAGS=-DHAVE_ALLOCA_H",
        "--with-sysroot=" + ctx.dep("musl").prefix,
        "--with-native-system-header-dir=/include",
        "--with-gmp=" + ctx.dep("gmp").prefix,
        "--with-mpfr=" + ctx.dep("mpfr").prefix,
        "--with-mpc=" + ctx.dep("mpc").prefix,
        "--with-as=" + binutils + "/bin/as",
        "--with-ld=" + binutils + "/bin/ld",
        "--enable-static",
        "--enable-threads=single",
        "--disable-threads",
        "--disable-libstdcxx-pch",
        "--disable-build-with-cxx",
        "--disable-plugin",
        "--disable-libcilkrts",
        "--disable-libmudflap",
    ]

def build_args(ctx):
    return ["MAKEINFO=true"]

def install(ctx):
    return [run("make", "install", "MAKEINFO=true")]
