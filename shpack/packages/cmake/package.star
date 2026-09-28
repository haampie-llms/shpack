# SPDX-License-Identifier: MIT

"""CMake 3.31.11 -- build-system generator. Bootstrapped from source against
store libraries (curl/openssl/libarchive/...); only the bundled cppdap
(cmake-only build) stays vendored. No ncurses dialog."""

load("//build_systems/lib.star", "replace_bin_sh")

homepage = "https://cmake.org/"
license("BSD-3-Clause")

version(
    "3.31.11",
    sha256 = "c0a3b3f2912b2166f522d5010ffb6029d8454ee635f5ad7a3247e0be7f9a15c9",
    url = "https://github.com/Kitware/CMake/releases/download/v3.31.11/cmake-3.31.11.tar.gz",
)

build_system("generic")

depends_on("compiler-wrapper", type = "build")
depends_on("gmake", type = "build")
depends_on("openssl")
depends_on("curl")
depends_on("zlib-ng")
depends_on("expat")
depends_on("bzip2")
depends_on("xz")
depends_on("zstd")
depends_on("nghttp2")
depends_on("libarchive")
depends_on("libuv")
depends_on("librhash")
depends_on("jsoncpp")
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("dash", type = "build")

def edit(ctx):
    # cmake hardcodes /bin/sh (the SHELL of generated makefiles, and its
    # cmExecProgramCommand); the sandbox has none.
    return [replace_bin_sh(ctx, ["Source/cmLocalUnixMakefileGenerator3.cxx",
                                 "Source/cmExecProgramCommand.cxx"])]

def install(ctx):
    wrapper = ctx.dep("compiler-wrapper").prefix
    # find_package() searches CMAKE_PREFIX_PATH, not the wrapper's -I/-L.
    prefix_path = ":".join([ctx.dep(d).prefix for d in [
        "openssl", "curl", "zlib-ng", "expat", "bzip2", "xz", "zstd", "nghttp2",
        "libarchive", "libuv", "librhash", "jsoncpp",
    ]])
    # Private deps of static libarchive.a; FindLibArchive links only the .a.
    archive_private = "-lcrypto -llzma -lzstd -lbz2 -lz"
    return [
        setenv("CC", wrapper + "/bin/gcc"),
        setenv("CXX", wrapper + "/bin/g++"),
        # Vendored cppdap needs _GNU_SOURCE under GCC 16.
        setenv("CFLAGS", "-D_GNU_SOURCE"),
        setenv("CXXFLAGS", "-D_GNU_SOURCE"),
        setenv("CMAKE_PREFIX_PATH", prefix_path),
        # --bootstrap-system-*: else the wrapper's -I leaks system headers into the
        #   bundled libs the mini-cmake compiles.
        # RPATH_USE_LINK_PATH: survive CMake's install-time RPATH rewrite.
        run(
            ctx.sh,
            "./bootstrap",
            "--prefix=" + ctx.prefix,
            "--no-qt-gui",
            "--system-libs",
            "--system-curl",
            "--no-system-cppdap",
            "--bootstrap-system-libuv",
            "--bootstrap-system-jsoncpp",
            "--bootstrap-system-librhash",
            "--",
            "-DCMAKE_USE_OPENSSL=ON",
            "-DBUILD_CursesDialog=OFF",
            "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON",
            "-DCMAKE_C_STANDARD_LIBRARIES=" + archive_private,
            "-DCMAKE_CXX_STANDARD_LIBRARIES=" + archive_private,
        ),
        run("make", ctx.makejobs),
        run("make", "install"),
    ]
