# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "GCC 16.1.0, crippled (--without-headers, no target libc), built by "
                  + "gcc-boot1: just enough cc1/libgcc to compile glibc 2.43 "
                  + "(throwaway). Stage 2 of three; the shipped, glibc-linked GCC 16 "
                  + "is packages/gcc.",
    homepage = "https://gcc.gnu.org/",
    license = "GPL-3.0-or-later",
)

version(
    "16.1.0",
    sha256 = "50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79",
    url = "https://ftp.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz",
)

build_system("autotools")

# GCC forbids an in-tree build; configure/build/install all happen in _build/.
build_directory("_build")

# binutils-boot1 (2.46) supplies the as/ld it assembles with and bakes into its
# specs. sed/tar for 16's pax tarball.
depends_on("gmake", "grep@2.4-musl", "diffutils", "findutils")
depends_on(
    "gcc-boot1",
    "binutils-boot1",
    "sed@4.9-musl",
    "tar@1.35-musl",
    "xz@5.2.5-musl",
    "gawk@5.3.1",
)
depends_on("dash@0.5.12")

# GCC 16's download_prerequisites set (newer gmp/mpfr/mpc), in-tree.
resource(
    url = "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.bz2",
    sha256 = "ac28211a7cfb609bae2e2c8d6058d66c8fe96434f740cf6fe2e47b000d1c20cb",
)
resource(
    url = "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.bz2",
    sha256 = "b9df93635b20e4089c29623b19420c4ac848a1b29df1cfd59f26cab0d2666aa0",
)
resource(
    url = "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz",
    sha256 = "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8",
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
    return [
        # gmp's AC_PROG_LEX fatally runs flex if on PATH; flex is only used by
        # gmp demos, so skip the probe.
        setenv("ac_cv_prog_lex_root", "lex.yy"),
        # Force inhibit_libc: a native --without-headers build would otherwise
        # use a target libc; true makes libgcc build the minimal no-libc set.
        setenv("inhibit_libc", "true"),
        # Env-set to keep $stage_dir out of TOPLEVEL_CONFIGURE_ARGUMENTS.
        # file_prefix_map goes in CPPFLAGS, not CFLAGS/CXXFLAGS: genchecksum
        # hashes ALL_LINKERFLAGS (= ALL_CXXFLAGS) into cc1's checksum but not
        # ALL_CPPFLAGS, so the scratch path never enters the hash.
        setenv("CFLAGS", "-O2"),
        setenv("CXXFLAGS", "-O2"),
        setenv("CPPFLAGS", ctx.file_prefix_map),
        setenv("CFLAGS_FOR_TARGET", "-O2 " + ctx.file_prefix_map),
        setenv("CXXFLAGS_FOR_TARGET", "-O2 " + ctx.file_prefix_map),
    ]

# --prefix and --disable-dependency-tracking come from the autotools configure.
def configure_args(ctx):
    t = triple(ctx)
    gcc = ctx.dep("gcc-boot1").prefix
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
        # Crippled boot: no target libc. --without-headers, header-dir
        # /nonexistent (never consulted under inhibit_libc), --disable-fixincludes
        # so it never scans host headers. No libstdc++-v3/libcc1 (gcc 9 has only
        # static musl). Just enough cc1/libgcc to compile glibc.
        "CC=" + gcc + "/bin/gcc",
        "CXX=" + gcc + "/bin/g++",
        "--without-headers",
        "--disable-fixincludes",
        "--with-native-system-header-dir=/nonexistent",
        "--disable-libstdc++-v3",
        "--disable-libcc1",
        "--without-isl",
        "--disable-threads",
        "--disable-nls",
    ]

def build_args(ctx):
    return ["MAKEINFO=true"]

def install(ctx):
    # glibc links libgcc_eh; the crippled build only makes libgcc.a (which
    # holds the EH objects), so alias it.
    gcc_lib = "%s/lib/gcc/%s/16.1.0" % (ctx.prefix, triple(ctx))
    return [
        run("make", "install", "MAKEINFO=true"),
        symlink("libgcc.a", gcc_lib + "/libgcc_eh.a", if_missing = True),
    ]
