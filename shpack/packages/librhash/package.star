# SPDX-License-Identifier: MIT

package(
    description = "LibRHash 1.4.6 -- hash/checksum library (the librhash part of "
                  + "RHash). Static library + headers only; no OpenSSL backend, no "
                  + "gettext.",
    homepage = "https://rhash.sourceforge.net/",
    license = "0BSD",
)

version(
    "1.4.6",
    sha256 = "9f6019cfeeae8ace7067ad22da4e4f857bb2cfa6c2deaa2258f55b2227ec937a",
    url = "https://github.com/rhash/RHash/archive/v1.4.6.tar.gz",
    fname = "rhash-1.4.6.tar.gz",
)

build_system("generic")

depends_on("compiler-wrapper", "gmake")
depends_on("dash")

def install(ctx):
    # Hand-written configure (not autotools); honours $CC.
    return [
        setenv("CC", "gcc"),
        run(ctx.sh, "./configure", "--prefix=" + ctx.prefix,
            "--disable-openssl", "--disable-gettext", "--enable-lib-static"),
        run("make", "SHELL=" + ctx.sh, ctx.makejobs, "lib-static"),
        run("make", "SHELL=" + ctx.sh, "install-lib-static"),
    ]
