# SPDX-License-Identifier: MIT

"""GNU awk. 5.3.1 is the modern awk the glibc cap needs (glibc 2.43's configure
rejects 3.0.4, gawk-boot, as too old, < 3.1.2); 5.3.2 is the glibc awk built
with the final gcc 16, user-facing."""

load("//build_systems/lib.star", "replace_bin_sh", "triple")

homepage = "https://www.gnu.org/software/gawk/"
license("GPL-2.0-or-later")

# Newest first: a bare gawk resolves to the first declared version (5.3.2, the
# user-facing awk). The earlier stages all pin the version they need.

# 5.3.2: built with the final gcc 16 against glibc -- the user-facing awk.
version(
    "5.3.2",
    sha256 = "f8c3486509de705192138b00ef2c00bbbdd0e84c30d5c07d23fc73a9dc4cc9cc",
    url = "https://ftpmirror.gnu.org/gawk/gawk-5.3.2.tar.xz",
)

# 5.3.1: built by the gcc-9.5 bridge against static musl 1.2.5; the modern awk
# the glibc cap needs (glibc 2.43's configure rejects 3.0.4 as too old).
version(
    "5.3.1",
    sha256 = "694db764812a6236423d4ff40ceb7b6c4c441301b72ad502bb5c27e00cd56f78",
    url = "https://ftp.gnu.org/gnu/gawk/gawk-5.3.1.tar.xz",
)

# Both are autotools and differ only in configure_args (below).
build_system("autotools")

# Both configure with the tcc-built awk and grep: a package never depends on
# another version of itself.
depends_on("gawk-boot", type = "build")
depends_on("grep-boot", type = "build")
# 5.3.1: gcc 9.5 + binutils 2.30. Modern sed/tar: 5.3.1's configure needs sed -E
# and its tarball is xz.
depends_on("gcc-boot1", when = "@=5.3.1", type = "build")
depends_on("binutils-boot0", when = "@=5.3.1", type = "build")
depends_on("gmake", when = "@=5.3.1", type = "build")
depends_on("sed@4.9-musl", when = "@=5.3.1", type = "build")
depends_on("tar@1.35-musl", when = "@=5.3.1", type = "build")
depends_on("xz@5.2.5-musl", when = "@=5.3.1", type = "build")
# 5.3.2: gcc 16 via compiler-wrapper, with the glibc sed/tar/xz build tools.
depends_on("compiler-wrapper", when = "@=5.3.2", type = "build")
depends_on("gmake", when = "@=5.3.2", type = "build")
depends_on("sed", when = "@=5.3.2", type = "build")
depends_on("tar", when = "@=5.3.2", type = "build")
depends_on("xz", when = "@=5.3.2", type = "build")
# replace_bin_sh (below) compiles the shell path into the gawk binary: 5.3.2
# (glibc) ships the clean dash, 5.3.1 the bootstrap one.
depends_on("diffutils", when = "@=5.3.2", type = "build")
depends_on("findutils", when = "@=5.3.2", type = "build")
depends_on("dash", when = "@=5.3.2", type = "build")
depends_on("diffutils", when = "@=5.3.1", type = "build")
depends_on("findutils", when = "@=5.3.1", type = "build")
depends_on("dash@0.5.12", when = "@=5.3.1", type = "build")

def edit(ctx):
    # gawk's system()/getline/print-to-cmd execl a hardcoded "/bin/sh", which the
    # musl patch can't reach and the sandbox denies. Repoint at the store shell
    # (glibc's gen-sorted.awk does system("test -d ...") during the build).
    return [replace_bin_sh(ctx, ["builtin.c", "io.c"])]

# 5.3.1/5.3.2. Both disable loadable .so extensions (unused; for 5.3.1 they also
# can't link the non-PIC static musl libc.a) and NLS/mpfr/libsigsegv. They differ
# only in compiler/CFLAGS: 5.3.1 uses the gcc-9.5 bridge with CFLAGS=-O2 to drop
# the default -g (would leak the build cwd as comp_dir); 5.3.2 uses gcc 16.
def configure_args(ctx):
    if ctx.satisfies("@=5.3.1"):
        t = triple(ctx, "musl")
        args = ["CC=" + ctx.dep("gcc-boot1").prefix + "/bin/gcc", "CFLAGS=-O2"]
    else:
        t = triple(ctx)
        args = ["CC=gcc"]
    return args + [
        "MAKEINFO=true",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
        "--disable-mpfr",
        "--disable-extensions",
        "--without-libsigsegv-prefix",
    ]
