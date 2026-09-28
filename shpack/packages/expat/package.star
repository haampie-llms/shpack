# SPDX-License-Identifier: MIT

"""Expat 2.8.1 -- a stream-oriented XML parser library written in C. Small
autotools build."""

load("//build_systems/lib.star", "triple")

homepage = "https://libexpat.github.io/"
license("MIT")

# GitHub release tarball (R_2_8_1/expat-2.8.1.tar.bz2).
version(
    "2.8.1",
    sha256 = "f5833dd2e1cd7739ec9182804a1a29c4f0cc7c2f26b633d3a2188b7766a88ecb",
    url = "https://github.com/libexpat/libexpat/releases/download/R_2_8_1/expat-2.8.1.tar.bz2",
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
    # --without-docbook (no doc toolchain) + --enable-static. No libbsd: glibc
    # 2.43 provides getrandom for expat's entropy source. Explicit glibc triple
    # (no uname/config.guess in the sandbox).
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--without-docbook",
        "--enable-static",
    ]
