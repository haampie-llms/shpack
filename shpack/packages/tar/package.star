# SPDX-License-Identifier: MIT

"""GNU tar 1.35 -- a modern archiver. The stage0 seed tar is 1.12 (1999), which
cannot extract POSIX pax-format tarballs (gcc 9.5+, glibc, binutils 2.46,
python all ship pax). The same source builds two ways: 1.35-musl is the static
musl tar the bootstrap chain uses to unpack pax sources before the final
toolchain exists; 1.35 is the glibc tar built with the final gcc 16, the
user-facing archiver."""

load("//build_systems/lib.star", "replace_bin_sh", "triple")

homepage = "https://www.gnu.org/software/tar/"
license("GPL-3.0-or-later")

# tar's own release tarball is plain ustar/gnu, so the seed tar-1.12 can unpack
# this source. The same source builds two ways under separate version strings.
version(
    "1.35",
    sha256 = "14d55e32063ea9526e057fbf35fcabd53378e769787eff7919c3755b02d2b57e",
    url = "https://ftpmirror.gnu.org/tar/tar-1.35.tar.gz",
)
version(
    "1.35-musl",
    sha256 = "14d55e32063ea9526e057fbf35fcabd53378e769787eff7919c3755b02d2b57e",
    url = "https://ftpmirror.gnu.org/tar/tar-1.35.tar.gz",
)

build_system("autotools")

# 1.35-musl: built by GCC 4.7 against musl 1.1.24 (static). 1.35: the glibc tar,
# built with the final gcc 16 via compiler-wrapper.
depends_on("gcc-boot0", when = "@=1.35-musl", type = "build")
depends_on("binutils-boot0", when = "@=1.35-musl", type = "build")
depends_on("gmake", when = "@=1.35-musl", type = "build")
depends_on("compiler-wrapper", when = "@=1.35", type = "build")
depends_on("gmake", when = "@=1.35", type = "build")
# replace_bin_sh (below) compiles the shell path into the tar binary, a runtime
# dep: 1.35 (glibc) ships the clean dash, 1.35-musl the tcc-built bootstrap one.
depends_on("sed@4.9-musl", when = "@=1.35", type = "build")
depends_on("grep-boot", when = "@=1.35", type = "build")
depends_on("gawk@5.3.1", when = "@=1.35", type = "build")
depends_on("diffutils", when = "@=1.35", type = "build")
depends_on("findutils", when = "@=1.35", type = "build")
depends_on("xz@5.2.5-musl", when = "@=1.35", type = "build")
depends_on("dash", when = "@=1.35", type = "build")
depends_on("grep-boot", when = "@=1.35-musl", type = "build")
depends_on("gawk-boot", when = "@=1.35-musl", type = "build")
depends_on("diffutils", when = "@=1.35-musl", type = "build")
depends_on("findutils", when = "@=1.35-musl", type = "build")
depends_on("dash@0.5.12", when = "@=1.35-musl", type = "build")

def setup_build_environment(ctx):
    # tar's configure refuses to run as root unless told the rmt setup is
    # intentional; belt-and-suspenders since the chroot drops to the real uid.
    return [setenv("FORCE_UNSAFE_CONFIGURE", "1")]

def edit(ctx):
    # tar runs compressors via a hardcoded execv("/bin/sh", -c) in src/system.c;
    # the sandbox denies host /bin/sh, so `tar czf` would fail.
    return [replace_bin_sh(ctx, "src/system.c")]

def configure_args(ctx):
    musl = ctx.satisfies("@=1.35-musl")
    # Explicit triple (no config.guess); musl vs glibc differ only here.
    t = triple(ctx, "musl", vendor = "unknown") if musl else triple(ctx)
    args = [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
    ]
    # gcc 4.7 has no -ffile-prefix-map, so CFLAGS=-O2 drops the default -g (would
    # leak the build cwd as comp_dir). gcc 16's -g is reproducible.
    if musl:
        args.append("CFLAGS=-O2")
    return args
