# SPDX-License-Identifier: MIT

"""libarchive 3.8.7 -- multi-format archive/compression library. Static
libarchive only; zlib/bzip2/xz/zstd/openssl filters, no CLI tools."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.libarchive.org/"
license("BSD-2-Clause")

version(
    "3.8.7",
    sha256 = "4b787cca6697a95c7725e45293c973c208cbdc71ae2279f30ef09f52472b9166",
    url = "https://github.com/libarchive/libarchive/releases/download/v3.8.7/libarchive-3.8.7.tar.gz",
)

build_system("autotools")

depends_on("compiler-wrapper", type = "build")
depends_on("gmake", type = "build")
depends_on("zlib-ng")
depends_on("bzip2")
depends_on("xz")
depends_on("zstd")
depends_on("openssl")
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("dash", type = "build")

def configure_args(ctx):
    # zlib/bzip2/lzma/zstd/openssl filters on, everything else off, no tools.
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--enable-static",
        "--disable-shared",
        "--disable-bsdtar",
        "--disable-bsdcpio",
        "--disable-bsdcat",
        "--disable-bsdunzip",
        "--disable-acl",
        "--disable-xattr",
        "--with-zlib",
        "--with-bz2lib",
        "--with-lzma",
        "--with-zstd",
        "--with-openssl",
        "--without-xml2",
        "--without-expat",
        "--without-lz4",
        "--without-lzo2",
        "--without-nettle",
        "--without-mbedtls",
        "--without-iconv",
    ]
