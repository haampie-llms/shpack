# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "Multiple-precision floating-point library (gcc prerequisite)",
    homepage = "https://www.mpfr.org/",
    license = "LGPL-2.1-or-later",
)

version(
    "2.4.2",
    sha256 = "246d7e184048b1fc48d3696dd302c9774e24e921204221540745e5464022b637",
    url = "https://ftpmirror.gnu.org/mpfr/mpfr-2.4.2.tar.gz",
)

build_system("autotools")

depends_on(
    "tcc",
    "musl@1.1.24",
    "gmake",
    "binutils-boot0",
    "gmp",
    "grep@2.4-musl",
    "gawk@3.0.4",
)
depends_on("dash@0.5.12")

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
