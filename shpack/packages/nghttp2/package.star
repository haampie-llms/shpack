# SPDX-License-Identifier: MIT

"""nghttp2 1.67.1 -- an HTTP/2 and HPACK implementation in C. Only libnghttp2
is built (--enable-lib-only); the bundled apps would pull in libev and friends.
"""

load("//build_systems/lib.star", "triple")

homepage = "https://nghttp2.org/"
license("MIT")

version(
    "1.67.1",
    sha256 = "da8d640f55036b1f5c9cd950083248ec956256959dc74584e12c43550d6ec0ef",
    url = "https://github.com/nghttp2/nghttp2/releases/download/v1.67.1/nghttp2-1.67.1.tar.gz",
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
    # Library only: no apps, so none of the optional deps below are needed; the
    # --with-*=no set keeps configure from picking anything up from the environment.
    # Explicit glibc triple because the sandbox has no uname/config.guess.
    t = triple(ctx)
    return [
        "CC=gcc",
        "CXX=g++",
        "--build=" + t,
        "--host=" + t,
        "--enable-lib-only",
        "--with-libxml2=no",
        "--with-jansson=no",
        "--with-zlib=no",
        "--with-libevent-openssl=no",
        "--with-libcares=no",
        "--with-openssl=no",
        "--with-libev=no",
        "--with-cunit=no",
        "--with-jemalloc=no",
        "--with-systemd=no",
        "--with-mruby=no",
        "--with-neverbleed=no",
        "--with-boost=no",
        "--with-wolfssl=no",
    ]
