# SPDX-License-Identifier: MIT

"""libuv 1.52.0 -- cross-platform asynchronous I/O library. Static libuv only.
"""

load("//build_systems/lib.star", "triple")

homepage = "https://libuv.org/"
license("MIT")

# The -dist tarball ships a pregenerated configure (no autoconf in the bootstrap).
version(
    "1.52.0",
    sha256 = "a34f3eaabff4cb9e08b17a25b459f8330e6536d256a3180e249e8cb2bb49ccd6",
    url = "https://dist.libuv.org/dist/v1.52.0/libuv-v1.52.0-dist.tar.gz",
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
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--enable-static",
        "--disable-shared",
    ]
