# SPDX-License-Identifier: MIT

"""libffi 3.4.6 -- foreign function interface. Provides CPython's _ctypes,
which Spack imports at startup (archspec CPU detection via ctypes), so it's
required even though clingo uses the C-API."""

load("//build_systems/lib.star", "triple")

homepage = "https://sourceware.org/libffi/"
license("MIT")

version(
    "3.4.6",
    sha256 = "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e",
    url = "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz",
)

build_system("autotools")

depends_on("compiler-wrapper", type = "build")
depends_on("gmake", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("dash", type = "build")

def configure_args(ctx):
    # Explicit triple (no date/uname for config.guess). --disable-multi-os-directory
    # keeps the lib in lib/ (not a multiarch subdir) so the wrapper's -L finds it.
    # --disable-docs drops the doc/ subdir (no makeinfo in the store).
    t = triple(ctx)
    return [
        "CC=gcc",
        "CXX=g++",
        "--build=" + t,
        "--host=" + t,
        "--with-pic",
        "--disable-multi-os-directory",
        "--disable-docs",
    ]
