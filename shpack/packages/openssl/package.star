# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "cpu")

package(
    description = "OpenSSL 3.6.1 -- TLS/crypto library. Provides CPython's _ssl, "
                  + "which Spack imports unconditionally (spack.util.web -> ssl), so "
                  + "it's required even for offline 'spack spec'.",
    homepage = "https://www.openssl.org/",
    license = "Apache-2.0",
)

version(
    "3.6.1",
    sha256 = "b1bfedcd5b289ff22aee87c9d600f515767ebf45f77168cb6d64f231f518a82e",
    url = "https://github.com/openssl/openssl/releases/download/openssl-3.6.1/openssl-3.6.1.tar.gz",
)

build_system("generic")

# perl drives Configure and the build generators; zlib-ng for compression.
# ca-certificates is the Mozilla bundle dropped into OPENSSLDIR (see install) so
# the default trust store works with no SSL_CERT_FILE.
depends_on("compiler-wrapper", "perl", "zlib-ng", "gmake", "ca-certificates")
depends_on("dash")

def install(ctx):
    perl = ctx.dep("perl").prefix
    return [
        setenv("CC", ctx.dep("compiler-wrapper").prefix + "/bin/gcc"),
        prepend_path("PATH", perl + "/bin"),
        # Explicit target ("linux-$m") so Configure never guesses via uname/config.
        # --libdir=lib keeps the libs in lib/ where the wrapper's -L looks; -Wl,-rpath
        # lets them resolve from the store with no LD_LIBRARY_PATH.
        run(perl + "/bin/perl", "./Configure", "linux-" + cpu(ctx),
            "--prefix=" + ctx.prefix,
            "--openssldir=" + ctx.prefix + "/ssl",
            "--libdir=lib",
            "shared", "zlib",
            "-Wl,-rpath," + ctx.prefix + "/lib"),
        run("make", ctx.makejobs),
        # install_sw: libs + headers + tool, skipping man pages (need a doc toolchain).
        run("make", "install_sw"),
        # Drop the bundle at OPENSSLDIR/cert.pem (X509_get_default_cert_file()) so TLS
        # clients verify without SSL_CERT_FILE. install_sw skips the ssl/ dir, so
        # create it first.
        mkdir(ctx.prefix + "/ssl"),
        copy(ctx.dep("ca-certificates").prefix + "/etc/ssl/cert.pem", ctx.prefix + "/ssl/cert.pem"),
    ]
