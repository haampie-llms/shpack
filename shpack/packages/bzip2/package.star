# SPDX-License-Identifier: MIT

package(
    description = "bzip2 1.0.8 -- a block-sorting file compressor: the bzip2/bunzip2 "
                  + "CLI plus the shared libbz2. Built at the gcc-16 layer.",
    homepage = "https://sourceware.org/bzip2/",
    license = "bzip2-1.0.6",
)

version(
    "1.0.8",
    sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
    url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz",
)

build_system("generic")

# compiler-wrapper pulls in gcc 16 + glibc loader/rpath. Pure-make build (two
# hand-written Makefiles), no configure, no /bin/sh hardcoding.
depends_on("compiler-wrapper", "gmake")
depends_on("dash")

def edit(ctx):
    # Both Makefiles hardcode CC=gcc; repoint at the wrapper gcc (= gcc 16).
    cc = ctx.dep("compiler-wrapper").prefix + "/bin/gcc"
    return [filter_file(["Makefile", "Makefile-libbz2_so"], "^CC=gcc", "CC=" + cc)]

def install(ctx):
    lib = ctx.prefix + "/lib"
    bin = ctx.prefix + "/bin"
    return [
        # Shared lib first: Makefile-libbz2_so builds libbz2.so.1.0.8 + bzip2-shared.
        run("make", "-f", "Makefile-libbz2_so", "SHELL=" + ctx.sh, ctx.makejobs),
        # Then the static lib, the CLI, and man pages; install lays out bin/lib/include.
        run("make", "SHELL=" + ctx.sh, ctx.makejobs),
        run("make", "SHELL=" + ctx.sh, "PREFIX=" + ctx.prefix, "install"),
        # Overlay the dynamic build: the shared bzip2 over the static one, the
        # versioned .so, and the classic symlink chain.
        run("install", "-m", "755", "bzip2-shared", bin + "/bzip2"),
        run("install", "-m", "755", "libbz2.so.1.0.8", lib + "/libbz2.so.1.0.8"),
    ] + [
        symlink("libbz2.so.1.0.8", lib + "/" + l, force = True)
        for l in ["libbz2.so", "libbz2.so.1", "libbz2.so.1.0"]
    ] + [
        # bunzip2/bzcat are copies of the static bzip2; repoint them at the new one.
        remove([bin + "/bunzip2", bin + "/bzcat"]),
        symlink("bzip2", bin + "/bunzip2"),
        symlink("bzip2", bin + "/bzcat"),
    ]
