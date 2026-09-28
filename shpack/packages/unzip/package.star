# SPDX-License-Identifier: MIT

"""Info-ZIP unzip 6.0 -- the unzip CLI for .zip archives. Ancient (2009) K&R C,
so it needs -std=gnu89 and a couple of -Wno-error knobs to compile with gcc 16.
"""

homepage = "https://infozip.sourceforge.net/UnZip.html"
license("Info-ZIP")

# Info-ZIP's tarball is unzip60.tar.gz (version digits joined), extracting unzip60/.
version(
    "6.0",
    sha256 = "036d96991646d0449ed0aa952e4fbe21b476ce994abc276e49d30e686708bd37",
    url = "https://downloads.sourceforge.net/infozip/unzip60.tar.gz",
)

build_system("generic")

# compiler-wrapper supplies gcc 16 + glibc. Builds from unix/Makefile via the
# `generic` target, which runs Info-ZIP's unix/configure feature probe first.
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

# Upstream/distros carry many CVE/hardening patches for unzip 6.0; not
# build-blocking, deferred here. Revisit before feeding untrusted input.

def install(ctx):
    # Fold the implicit-decl downgrades into CC, not LOC/CFLAGS: unix/configure's
    # probes compile with bare $CC. On gcc 16 they hit fatal implicit-decl errors,
    # configure falls back to -DNO_DIR, and unix.c's homebrew DIR collides with
    # glibc's dirent.h. Passing the flags on CC lets the probes pass.
    cc = ctx.dep("compiler-wrapper").prefix + "/bin/gcc -Wno-error=implicit-function-declaration -Wno-error=implicit-int"
    # Enable large files; force the gnu89 dialect the K&R sources assume.
    loc = "-DLARGE_FILE_SUPPORT -std=gnu89"
    # No -j: the 2009 Makefile's recursive `generic` target is not parallel-safe.
    return [
        run("make", "-f", "unix/Makefile", "SHELL=" + ctx.sh, "CC=" + cc, "LOC=" + loc, "generic"),
        run("make", "-f", "unix/Makefile", "SHELL=" + ctx.sh, "CC=" + cc, "LOC=" + loc,
            "prefix=" + ctx.prefix, "install"),
    ]
