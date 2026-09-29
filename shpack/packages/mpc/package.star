# SPDX-License-Identifier: MIT

"""Multiple-precision complex arithmetic library (gcc prerequisite)"""

load("//build_systems/lib.star", "triple")

homepage = "https://www.multiprecision.org/mpc/"
license("LGPL-3.0-or-later")

version(
    "1.0.3",
    sha256 = "617decc6ea09889fb08ede330917a00b16809b8db88c29c31bfbb49cbf88ecc3",
    url = "https://ftpmirror.gnu.org/mpc/mpc-1.0.3.tar.gz",
)

build_system("autotools")

depends_on("tcc", type = ("build", "link"))
depends_on("gmake", type = "build")
depends_on("binutils-boot0", type = "build")
depends_on("gmp")
depends_on("mpfr")
depends_on("grep-boot", type = "build")
depends_on("gawk-boot", type = "build")
depends_on("diffutils", type = "build")
depends_on("dash-boot", type = "build")

def configure_args(ctx):
    # config.guess cannot probe this environment (uname says "unknown", no
    # /usr/bin/file), so pass an explicit triple, matching gmp/mpfr.
    t = triple(ctx, vendor = "unknown")
    return [
        "CC=tcc",
        "CFLAGS=-DHAVE_ALLOCA_H",
        "--build=" + t,
        "--host=" + t,
        "--with-gmp=" + ctx.dep("gmp").prefix,
        "--with-mpfr=" + ctx.dep("mpfr").prefix,
        "--enable-static",
        "--disable-shared",
    ]
