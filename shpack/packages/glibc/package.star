# SPDX-License-Identifier: MIT

"""glibc 2.43 -- the production aarch64 libc, built by the crippled
gcc-16-boot0. Second half of the musl->glibc transition; every later cap stage
links against this. Two builds from one recipe: 2.43-boot is a throwaway built
with the bootstrap shell; 2.43 is the final libc, identical except its
ldd/mtrace/sotruss/tzselect/ xtrace scripts point at a clean, glibc-linked dash
instead of the tcc/musl bootstrap one."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.gnu.org/software/libc/"
license("LGPL-2.1-or-later")

version(
    "2.43",
    sha256 = "d9c86c6b5dbddb43a3e08270c5844fc5177d19442cf5b8df4be7c07cd5fa3831",
    url = "https://ftp.gnu.org/gnu/glibc/glibc-2.43.tar.xz",
)
version(
    "2.43-boot",
    sha256 = "d9c86c6b5dbddb43a3e08270c5844fc5177d19442cf5b8df4be7c07cd5fa3831",
    url = "https://ftp.gnu.org/gnu/glibc/glibc-2.43.tar.xz",
)

build_system("generic")

# Built by gcc-16-boot0 (unwrapped: glibc drives its own -nostdlib bootstrap).
# binutils-boot1 as/ld; kernel headers via --with-headers. Needs python
# (gen-as-const), bison+m4 (intl/plural.c), make >= 4, gawk@5.3.1 (configure
# rejects gawk < 3.1.2).
depends_on("gcc-boot2", type = "build")
depends_on("binutils-boot1", type = "build")
depends_on("linux-headers")
depends_on("gmake", type = "build")
depends_on("python", type = "build")
depends_on("bison", type = "build")
depends_on("m4", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("grep-boot", type = "build")
depends_on("diffutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
# glibc bakes a dash into its shipped scripts (ldd, mtrace, ...). 2.43 ships the
# clean dash; 2.43-boot breaks the dash->glibc cycle, so it uses the bootstrap
# dash (dash-boot, built by the kaem phase, hence no cycle). $sh follows whichever is
# declared.
depends_on("findutils", type = "build")
depends_on("dash", when = "@=2.43", type = "build")
depends_on("dash-boot", when = "@=2.43-boot", type = "build")

def install(ctx):
    headers = ctx.dep("linux-headers").prefix
    t = triple(ctx)

    # reduce build time of the "boot" version
    boot = ctx.satisfies("@=2.43-boot")
    stripped = ["--disable-default-pie", "--disable-timezone-tools"] if boot else []
    bp = ["build-programs=no"] if boot else []

    return [
        # glibc requires an out-of-tree build.
        mkdir("build"),
        chdir("build"),
        run(
            ctx.sh,
            "../configure",
            "CONFIG_SHELL=" + ctx.sh,
            "SHELL=" + ctx.sh,
            "CC=" + ctx.dep("gcc-boot2").prefix + "/bin/gcc",
            "CFLAGS=-g -O2 %s %s" % (ctx.file_prefix_map, ctx.debug_prefix_map),
            "BASH_SHELL=" + ctx.sh,
            "PYTHON=" + ctx.dep("python").prefix + "/bin/python3",
            "--build=" + t,
            "--host=" + t,
            "--prefix=" + ctx.prefix,
            "--with-headers=" + headers + "/include",
            "--enable-kernel=4.18.0",
            "--disable-nls",
            "--disable-werror",
            "--disable-profile",
            "--with-default-link=no",
            stripped,
        ),
        run("make", bp, ctx.makejobs),
        run("make", bp, "install"),
        # Make <prefix>/include complete: symlink the kernel headers beside glibc's
        # so one --with-native-system-header-dir covers both for the shipped gcc.
        symlink_each(headers + "/include/*", ctx.prefix + "/include", if_missing = True),
    ]
