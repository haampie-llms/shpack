# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "Intermediate aarch64 libstdc++ (static-only) from GCC 16 source. "
                  + "gcc-boot2 was built --disable-libstdc++-v3, but binutils "
                  + "(gprofng) and gcc's build tools need to link one.",
    homepage = "https://gcc.gnu.org/",
    license = "GPL-3.0-or-later",
)

# Same GCC 16 source as gcc-boot2 / gcc; only libstdc++-v3 is configured.
version(
    "16.1.0",
    sha256 = "50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79",
    url = "https://ftp.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz",
)

build_system("generic")

# Built by gcc-boot-wrapper against glibc 2.43 (static libstdc++.a, no .so).
# linux-headers: autoconf CPP sanity check. findutils: libtool merges the
# convenience archives into libstdc++.a by enumerating objects with find --
# without it the archive ships only compatibility*.o and C++ links break.
depends_on(
    "gcc-boot-wrapper",
    "glibc",
    "linux-headers",
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

def setup_build_environment(ctx):
    # libstdc++ #include_next <stdlib.h> etc. must reach glibc's headers.
    glibc = ctx.dep("glibc").prefix
    return [
        setenv("CPLUS_INCLUDE_PATH", glibc + "/include"),
        setenv("C_INCLUDE_PATH", glibc + "/include"),
        setenv("LIBRARY_PATH", glibc + "/lib"),
    ]

def edit(ctx):
    return [
        # libstdc++-v3 configure probes `g++ -v`; no-op it so it can't fail when the
        # compiler binary name differs.
        substitute("libstdc++-v3/configure", "g++ -v", "true"),
        # `date > stamp-*` just touches a make stamp; `date` isn't in the seed
        # coreutils and a real timestamp is non-reproducible -- use `touch`.
        substitute("libstdc++-v3/src/Makefile.in", "date > stamp", "touch stamp"),
    ]

def install(ctx):
    t = triple(ctx)
    gcc = ctx.dep("gcc-boot-wrapper").prefix
    return [
        mkdir("build"),
        chdir("build"),
        # Keep threads + dual-abi defaults on: GCC 16's C++20 tzdb.cc needs the cxx11
        # ABI's <chrono> tzdb. --disable-shared so downstream links it statically.
        #
        # LIBS=-lm: libstdc++'s AC_CHECK_FUNCS link tests (ceilf, cosf, ...) don't add
        # -lm, so they'd come out "no" -> _GLIBCXX_HAVE_CEILF undefined -> <cmath>
        # drops `using ::ceilf` -> the C++23 `std` module fails. Harmless to the .a.
        run(
            ctx.sh,
            "../libstdc++-v3/configure",
            "CONFIG_SHELL=" + ctx.sh,
            "CC=" + gcc + "/bin/gcc",
            "CXX=" + gcc + "/bin/g++",
            "CFLAGS=-g -O2 " + ctx.file_prefix_map,
            "CXXFLAGS=-g -O2 " + ctx.file_prefix_map,
            "MAKEINFO=true",
            "LIBS=-lm",
            "--build=" + t,
            "--host=" + t,
            "--prefix=" + ctx.prefix,
            "--disable-multilib",
            "--disable-nls",
            "--disable-shared",
            "--disable-libstdcxx-pch",
            "--with-gxx-include-dir=" + ctx.prefix + "/include",
        ),
        run("make", ctx.makejobs),
        run("make", "install"),
    ]
