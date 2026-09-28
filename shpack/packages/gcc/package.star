# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "ld_so", "triple")

package(
    description = "Native aarch64 GCC 16.1.0 -- the final, shared compiler of the "
                  + "bootstrap. Built by gcc-boot-wrapper against glibc 2.43 + "
                  + "binutils, --enable-shared, threads=posix, real C++ EH.",
    homepage = "https://gcc.gnu.org/",
    license = "GPL-3.0-or-later",
)

# The shared, glibc-linked production GCC 16. Same source as gcc-boot@16.1.0;
# the difference is how it's built (wrapped boot0 + glibc + binutils).
version(
    "16.1.0",
    sha256 = "50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79",
    url = "https://ftp.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz",
)

build_system("autotools")

# Built by gcc-boot-wrapper against glibc 2.43, binutils (as/ld baked in),
# libstdcxx-boot1 (static libstdc++.a for the build tools). linux-headers:
# autoconf CPP sanity check (also symlinked into glibc's include).
depends_on(
    "gcc-boot-wrapper",
    "glibc",
    "binutils",
    "libstdcxx-boot1",
    "linux-headers",
    "zlib-ng@2.3.3-boot",
    "zstd@1.5.7-boot",
    "gmake",
    "sed@4.9-musl",
    "grep@2.4-musl",
    "gawk@5.3.1",
    "diffutils",
    "findutils",
    "tar@1.35-musl",
    "xz@5.2.5-musl",
)
depends_on("dash")

# Same in-tree gmp/mpfr/mpc as gcc-boot@16.1.0 (GCC 16's prerequisite set).
resource(
    url = "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.bz2",
    sha256 = "ac28211a7cfb609bae2e2c8d6058d66c8fe96434f740cf6fe2e47b000d1c20cb",
    when = "@=16.1.0",
)
resource(
    url = "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.bz2",
    sha256 = "b9df93635b20e4089c29623b19420c4ac848a1b29df1cfd59f26cab0d2666aa0",
    when = "@=16.1.0",
)
resource(
    url = "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz",
    sha256 = "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8",
    when = "@=16.1.0",
)

def setup_build_environment(ctx):
    # The wrapped boot0 gcc has no default path to glibc's headers (it was
    # --without-headers), so host-side compiles (conftest, gengenrtl, ...) need
    # these on the include/library path. The in-tree libstdc++ compiles strip
    # libstdcxx-boot1 back out via the Makefile.in reset (configure()).
    glibc = ctx.dep("glibc").prefix
    libstdcxx = ctx.dep("libstdcxx-boot1").prefix
    zlib = ctx.dep("zlib-ng").prefix
    zstd = ctx.dep("zstd").prefix
    t = triple(ctx)
    return [
        # gmp's AC_PROG_LEX fatally runs flex if on PATH; flex is only used by
        # gmp demos, so skip the probe.
        setenv("ac_cv_prog_lex_root", "lex.yy"),
        # Static, glibc-linked zlib-ng/zstd (no .so -> static link into the compiler).
        setenv("C_INCLUDE_PATH", ":".join([glibc + "/include", zlib + "/include", zstd + "/include"])),
        setenv("CPLUS_INCLUDE_PATH", ":".join([
            libstdcxx + "/include", libstdcxx + "/include/" + t, glibc + "/include",
            zlib + "/include", zstd + "/include",
        ])),
        setenv("LIBRARY_PATH", ":".join([
            libstdcxx + "/lib64", libstdcxx + "/lib", glibc + "/lib", zlib + "/lib", zstd + "/lib",
        ])),
    ]

def edit(ctx):
    actions = []
    # Relocate the flat-unpacked resources into the GCC tree as gmp/ mpfr/ mpc/.
    for p in ["gmp", "mpfr", "mpc"]:
        actions += [
            move(ctx.stage_dir + "/" + p + "-*/", "./" + p),
            copy(["config.sub", "config.guess"], "./" + p + "/", force = True),
        ]
    # `date > stamp-*` just touches a make stamp; `date` isn't in the seed
    # coreutils and a real date is non-reproducible.
    return actions + [substitute("libstdc++-v3/src/Makefile.in", "date > stamp", "touch stamp")]

def configure(ctx):
    t = triple(ctx)
    gcc = ctx.dep("gcc-boot-wrapper").prefix
    glibc = ctx.dep("glibc").prefix
    libstdcxx = ctx.dep("libstdcxx-boot1").prefix
    binutils = ctx.dep("binutils").prefix
    zstd = ctx.dep("zstd").prefix
    # Flags for the freshly-built xgcc when it builds the target libs: point it
    # at glibc's loader + libs so its conftests link and run (see below).
    tflags = "-B{g}/lib -L{g}/lib -Wl,-rpath,{g}/lib -Wl,--dynamic-linker={g}/lib/{ld}".format(
        g = glibc, ld = ld_so(ctx))

    # GCC 16 makes implicit-function-declaration an error, failing gmp's
    # build-compiler probes (no CFLAGS). Wrap the boot0 gcc to demote it.
    relaxed = ctx.stage_dir + "/cc-relaxed.sh"

    # Strip libstdcxx-boot1 from CPLUS_INCLUDE_PATH for every libstdc++-v3 compile
    # (GCC bug 100017): its headers share include guards with the in-tree
    # libstdc++, so an in-tree #include_next would hit the boot1 wrapper and never
    # reach glibc's header. Reset to just glibc (kernel headers are symlinked in).
    reset = "CPLUS_INCLUDE_PATH = %s/include\nexport CPLUS_INCLUDE_PATH\n" % glibc

    return [
        write_file(relaxed, '#!%s\nexec %s/bin/gcc "$@" -Wno-error=implicit-function-declaration\n' %
                   (ctx.sh, gcc), mode = "755"),
        filter_file("libstdc++-v3/**/Makefile.in", "^AM_CXXFLAGS = ", reset + "AM_CXXFLAGS = "),
        # PCH rules use PCHFLAGS, not AM_CXXFLAGS. ^ avoids matching glibcxx_PCHFLAGS.
        filter_file("libstdc++-v3/include/Makefile.in", "^PCHFLAGS = ", reset + "PCHFLAGS = "),

        # Target-lib loader via *_FOR_TARGET, not --with-sysroot. xgcc's baked default
        # loader /lib/ld-linux-... is missing in our chroot, so target conftests fail
        # "cannot run C compiled programs". --with-sysroot makes ld double-prepend the
        # sysroot to the absolute paths in glibc's libc.so linker script. Instead pass
        # the loader/libdir as $tflags to the target compiler only; the installed
        # driver's runtime paths come from the specs file (install).
        # CFLAGS/CXXFLAGS=-O2 drops DWARF from host objects (cc1, ...); *_FOR_TARGET
        # keep -g so the shipped libs stay debuggable.
        # file_prefix_map goes in CPPFLAGS, not CFLAGS/CXXFLAGS: genchecksum hashes
        # ALL_LINKERFLAGS (= ALL_CXXFLAGS) into cc1's checksum but not ALL_CPPFLAGS,
        # so the $stage_dir path reaches every compile without entering the hash.
        setenv("CC", relaxed),
        setenv("CFLAGS", "-O2"),
        setenv("CXXFLAGS", "-O2"),
        setenv("CPPFLAGS", ctx.file_prefix_map),
        setenv("LDFLAGS", "-L%s/lib64 -L%s/lib" % (libstdcxx, libstdcxx)),
        setenv("CFLAGS_FOR_TARGET", "-g -O2 %s %s" % (tflags, ctx.file_prefix_map)),
        setenv("CXXFLAGS_FOR_TARGET", "-g -O2 %s %s" % (tflags, ctx.file_prefix_map)),
        setenv("LDFLAGS_FOR_TARGET", tflags),

        mkdir("build"),
        chdir("build"),
        run(
            ctx.sh,
            "../configure",
            "CONFIG_SHELL=" + ctx.sh,
            "CXX=" + gcc + "/bin/g++",
            "MAKEINFO=true",
            "--prefix=" + ctx.prefix,
            "--build=" + t,
            "--host=" + t,
            "--target=" + t,
            "--with-native-system-header-dir=" + glibc + "/include",
            "--with-as=" + binutils + "/bin/as",
            "--with-ld=" + binutils + "/bin/ld",
            "--enable-shared",
            "--enable-languages=c,c++",
            "--enable-threads=posix",
            "--enable-__cxa_atexit",
            "--disable-bootstrap",
            "--disable-dependency-tracking",
            "--disable-multilib",
            "--disable-werror",
            "--disable-nls",
            "--without-isl",
            "--disable-canonical-system-headers",
            "--with-system-zlib",
            "--with-zstd-include=" + zstd + "/include",
            "--with-zstd-lib=" + zstd + "/lib",
            "--disable-plugin",
        ),
    ]

def build_args(ctx):
    return ["MAKEINFO=true"]

# Appended to the full -dumpspecs set so *cc1_cpu (-march=native autodetection)
# survives; a partial specs file silently disables it. The leading blank line:
# $(...) strips dumpspecs' trailing one, and a double blank before '#' is
# "specs file malformed".
_SPECS_TAIL = """
# Generated by shpack: glibc loader/startfiles + binutils

*startfile_prefix_spec:
@GLIBC@/lib/

*link:
+ %{!static:%{!static-pie:--dynamic-linker @GLIBC@/lib/@LDSO@}}

*link_libgcc:
+ -rpath @GLIBC@/lib -L$rpath_dir -rpath $rpath_dir

*self_spec:
+ -B@BINUTILS@/bin/
"""

def install(ctx):
    specs_dir = "%s/lib/gcc/%s/16.1.0" % (ctx.prefix, triple(ctx))
    tail = _SPECS_TAIL.replace("@GLIBC@", ctx.dep("glibc").prefix) \
                      .replace("@LDSO@", ld_so(ctx)) \
                      .replace("@BINUTILS@", ctx.dep("binutils").prefix)
    # Write a specs file so plain gcc/g++ find glibc's startfiles + dynamic linker
    # and use binutils's as/ld -- no wrapper scripts or env vars needed. It is
    # derived from the installed driver (-dumpspecs) and from where libgcc_s
    # landed (lib64 or lib), so it is built by a script, not declared.
    script = "\n".join([
        'P=%s' % ctx.prefix,
        'if [ -n "$(ls "$P"/lib64/libgcc_s.* 2>/dev/null)" ]; then rpath_dir="$P/lib64"',
        'elif [ -n "$(ls "$P"/lib/libgcc_s.* 2>/dev/null)" ]; then rpath_dir="$P/lib"',
        'else echo "no libgcc_s.* found in lib/lib64" >&2; exit 1; fi',
        'mkdir -p %s' % specs_dir,
        'builtin_specs=$("$P/bin/gcc" -dumpspecs)',
        '{',
        '    printf "%s\\n" "$builtin_specs"',
        '    cat <<EOF',
        tail + 'EOF',
        '} > %s/specs' % specs_dir,
    ])
    return [
        run("make", "install", "MAKEINFO=true"),
        sh(script),
    ]
