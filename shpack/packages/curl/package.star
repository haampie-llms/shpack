# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "curl 8.20.0 -- the curl CLI and libcurl, a URL transfer library. "
                  + "TLS via OpenSSL with the Mozilla CA bundle; HTTP/2 via nghttp2; "
                  + "DEFLATE via zlib. All other optional backends are turned off.",
    homepage = "https://curl.se/",
    license = "curl",
)

version(
    "8.20.0",
    sha256 = "4be48e69cf467246cb97d369b85d78a08528f2b37cffef2418ee16e6a4eb596e",
    url = "https://curl.se/download/curl-8.20.0.tar.bz2",
)

build_system("autotools")

# openssl = TLS backend; zlib-ng = transfer-encoding inflate; nghttp2 = HTTP/2;
# ca-certificates = the on-disk trust store baked in as the default CA bundle.
# compiler-wrapper injects -I/-L/-rpath for the three libraries.
depends_on(
    "compiler-wrapper",
    "openssl",
    "zlib-ng",
    "nghttp2",
    "ca-certificates",
    "gmake",
)
depends_on("dash")

def configure_args(ctx):
    # Explicit glibc triple (no uname/config.guess in the sandbox). Dep prefixes
    # are passed by --with-DIR (no pkg-config in the base PATH); the wrapper also
    # injects -I/-L/-rpath. Only the backends we ship (openssl/zlib/nghttp2) are
    # enabled; the CA bundle is baked to the ca-certificates pem.
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--with-openssl=" + ctx.dep("openssl").prefix,
        "--with-zlib=" + ctx.dep("zlib-ng").prefix,
        "--with-nghttp2=" + ctx.dep("nghttp2").prefix,
        "--with-ca-bundle=" + ctx.dep("ca-certificates").prefix + "/etc/ssl/cert.pem",
        "--enable-shared",
        "--without-brotli",
        "--without-libpsl",
        "--without-libgsasl",
        "--without-zstd",
        "--without-libidn2",
        "--without-librtmp",
        "--without-libssh2",
        "--without-libssh",
        "--disable-ldap",
        "--without-gssapi",
        "--disable-docs",
        "--disable-manual",
    ]
