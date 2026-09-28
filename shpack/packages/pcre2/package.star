# SPDX-License-Identifier: MIT

"""PCRE2 10.44 -- a Perl-compatible regular expression library. Default 8-bit
libpcre2-8 build."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.pcre.org"
license("BSD-3-Clause")

# GitHub release tarball (pcre2-10.44/pcre2-10.44.tar.bz2).
version(
    "10.44",
    sha256 = "d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96",
    url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2",
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
    # Default 8-bit build (libpcre2-8). Explicit glibc triple (no
    # uname/config.guess in the sandbox).
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
    ]
