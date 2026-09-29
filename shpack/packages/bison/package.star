# SPDX-License-Identifier: MIT

"""GNU Bison 3.8.2, built by the gcc-9.5 bridge. glibc 2.43 invokes it at build
time to generate intl/plural.c."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.gnu.org/software/bison/"
license("GPL-3.0-or-later")

version(
    "3.8.2",
    sha256 = "9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2",
    url = "https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz",
)

build_system("autotools")

# Built by gcc 9.5 in the musl world (binutils-boot0 as/ld). m4 is a RUN dep:
# bison shells out to it to expand skeletons; seed m4@1.4.7 meets `m4 >= 1.4.6`.
depends_on("gcc-boot1", type = "build")
depends_on("binutils-boot0", type = "build")
depends_on("gmake", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("m4", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk-boot", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("dash-boot", type = "build")

def setup_build_environment(ctx):
    # No host flex; bison ships its generated scanners, so the only obstacle is
    # AC_PROG_LEX fatally running $LEX. Preseed to short-circuit it.
    return [setenv("ac_cv_prog_lex_root", "lex.yy")]

def configure_args(ctx):
    # CFLAGS=-O2 drops autotools' default -g: -g would leak the build cwd as the
    # DWARF comp_dir (see builder.sh).
    t = triple(ctx, "musl")
    return [
        "CC=" + ctx.dep("gcc-boot1").prefix + "/bin/gcc",
        "CFLAGS=-O2",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
        "ARFLAGS=crD",
    ]
