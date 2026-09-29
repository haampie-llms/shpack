# SPDX-License-Identifier: MIT

"""GCC 9.5, built by gcc-boot0's g++ against musl 1.2.5: the bridge to modern
GCC (throwaway). Stage 1 of three; mature C++17, builds cleanly on musl."""

load("//build_systems/lib.star", "triple")

homepage = "https://gcc.gnu.org/"
license("GPL-3.0-or-later")

version(
    "9.5.0",
    sha256 = "27769f64ef1d4cd5e2be8682c0c93f9887983e6cfd1a927ce5a0a2915a95cf8f",
    url = "https://ftpmirror.gnu.org/gcc/gcc-9.5.0/gcc-9.5.0.tar.xz",
)

build_system("autotools")

# GCC forbids an in-tree build; configure/build/install all happen in _build/.
build_directory = "_build"

# musl 1.2.5 sysroot, kernel headers, binutils 2.30. gmp/mpfr/mpc are in-tree
# resources (4.3.2/2.4.2 are too old).
depends_on("gmake", type = "build")
depends_on("grep-boot", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("gcc-boot0", type = "build")
depends_on("musl@1.2.5")
depends_on("linux-headers")
depends_on("binutils-boot0", type = ("build", "run"))
depends_on("m4@1.4.7", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("gawk-boot", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("dash-boot", type = "build")

# GCC 9.5's download_prerequisites set, in-tree as gmp/ mpfr/ mpc/ for
# auto-detection. ISL omitted (Graphite only; --without-isl).
resource(
    url = "https://ftpmirror.gnu.org/gmp/gmp-6.1.0.tar.bz2",
    sha256 = "498449a994efeba527885c10405993427995d3f86b8768d8cdf8d9dd7c6b73e8",
)
resource(
    url = "https://ftpmirror.gnu.org/mpfr/mpfr-3.1.4.tar.bz2",
    sha256 = "d3103a80cdad2407ed581f3618c4bed04e0c92d1cf771a65ead662cc397f7775",
)
resource(
    url = "https://ftpmirror.gnu.org/mpc/mpc-1.0.3.tar.gz",
    sha256 = "617decc6ea09889fb08ede330917a00b16809b8db88c29c31bfbb49cbf88ecc3",
)

def edit(ctx):
    # Relocate the flat-unpacked gmp/mpfr/mpc resources into the GCC tree for
    # auto-detection. cwd is the gcc source dir (it sorts first).
    actions = []
    for p in ["gmp", "mpfr", "mpc"]:
        actions += [
            move(ctx.stage_dir + "/" + p + "-*/", "./" + p),
            # The bundled config.sub/guess predate musl; overwrite with GCC's
            # pair. mpc ships them read-only (555); cp -f unlinks and retries.
            copy(["config.sub", "config.guess"], "./" + p + "/", force = True),
        ]
    return actions

def setup_build_environment(ctx):
    flags = "-O2 %s %s" % (ctx.file_prefix_map, ctx.debug_prefix_map)
    return [
        # gmp's AC_PROG_LEX fatally runs flex if on PATH; flex is only used by
        # gmp demos, so skip the probe.
        setenv("ac_cv_prog_lex_root", "lex.yy"),
        # In-tree mpfr.h (mpfr/src) must be found while GCC compiles, plus the
        # kernel uapi. source_dir is the gcc source dir (before the out-of-tree cd).
        setenv("C_INCLUDE_PATH", ctx.source_dir + "/mpfr/src:" +
               ctx.dep("linux-headers").prefix + "/include"),
        # -ffile-prefix-map for .c, but gcc 9.5's driver doesn't forward it to
        # the assembler, so libgcc's .S stubs leak comp_dir -- add the older
        # -fdebug-prefix-map, which it does forward. Env-passed.
        setenv("CFLAGS_FOR_TARGET", flags),
        setenv("CXXFLAGS_FOR_TARGET", flags),
    ]

# --prefix and --disable-dependency-tracking come from the autotools configure.
def configure_args(ctx):
    t = triple(ctx, "musl", vendor = "unknown")
    gcc = ctx.dep("gcc-boot0").prefix + "/bin/gcc"
    gxx = ctx.dep("gcc-boot0").prefix + "/bin/g++"
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
        # 4.7 g++, musl sysroot, in-tree gmp/mpfr/mpc. -O2 (not -g -O2): a
        # throwaway bridge, so DWARF on its ~2300 objects is pure cost.
        # CFLAGS/CXXFLAGS cover the host build; *_FOR_TARGET cover libgcc/libstdc++.
        "CC=" + gcc,
        "CXX=" + gxx,
        "CC_FOR_BUILD=" + gcc,
        "CXX_FOR_BUILD=" + gxx,
        "CFLAGS=-O2",
        "CXXFLAGS=-O2",
        "--with-sysroot=" + ctx.dep("musl").prefix,
        "--with-native-system-header-dir=/include",
        "--without-isl",
        "--enable-static",
        "--disable-libstdcxx-pch",
        "--disable-plugin",
        "--disable-libcilkrts",
        "--disable-libmudflap",
    ]

def build_args(ctx):
    return ["MAKEINFO=true"]

def install(ctx):
    return [run("make", "install", "MAKEINFO=true")]
