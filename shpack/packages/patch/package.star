# SPDX-License-Identifier: MIT

"""GNU patch 2.8 -- applies unified/context diffs produced by diff. Built at
the gcc-16 layer; the bootstrap seed patch is 2.5.9 (2002), this is the modern
replacement."""

load("//build_systems/lib.star", "triple")

homepage = "https://savannah.gnu.org/projects/patch/"
license("GPL-3.0-or-later")

version(
    "2.8",
    sha256 = "f87cee69eec2b4fcbf60a396b030ad6aa3415f192aa5f7ee84cad5e11f7f5ae3",
    url = "https://ftpmirror.gnu.org/patch/patch-2.8.tar.xz",
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

# Build out of source so a re-configure stays clean.
build_directory = "spack-build"

def configure_args(ctx):
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
    ]
