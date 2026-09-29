# SPDX-License-Identifier: MIT

"""Multiple-precision floating-point library (gcc prerequisite)"""

load("//build_systems/lib.star", "triple")

homepage = "https://www.mpfr.org/"
license("LGPL-2.1-or-later")

version(
    "2.4.2",
    sha256 = "246d7e184048b1fc48d3696dd302c9774e24e921204221540745e5464022b637",
    url = "https://ftpmirror.gnu.org/mpfr/mpfr-2.4.2.tar.gz",
)

build_system("autotools")

depends_on("tcc", type = ("build", "link"))
depends_on("gmake", type = "build")
depends_on("binutils-boot0", type = "build")
depends_on("gmp")
depends_on("grep-boot", type = "build")
depends_on("gawk-boot", type = "build")
depends_on("diffutils", type = "build")
depends_on("dash-boot", type = "build")

def configure_args(ctx):
    # config.sub predates musl; the triple is cosmetic for this native
    # pure-math-library build, so use a -gnu triple the old config.sub knows.
    t = triple(ctx, vendor = "unknown")
    return [
        "CC=tcc",
        "CFLAGS=-DHAVE_ALLOCA_H",
        "--build=" + t,
        "--host=" + t,
        "--with-gmp=" + ctx.dep("gmp").prefix,
        "--enable-static",
        "--disable-shared",
    ]
