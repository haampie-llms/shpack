# SPDX-License-Identifier: MIT

"""GNU grep 3.11, the modern glibc grep built with the final gcc 16, the
user-facing one (grep-boot is the tcc-built grep of the early chain)."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.gnu.org/software/grep/"
license("GPL-2.0-or-later")

# 3.11: autotools, built with gcc 16 against glibc -- the user-facing grep.
version(
    "3.11",
    sha256 = "1f31014953e71c3cddcedb97692ad7620cb9d6d04fbdc19e0d8dd836f87622bb",
    url = "https://ftpmirror.gnu.org/grep/grep-3.11.tar.gz",
)
build_system("autotools")

depends_on("compiler-wrapper", type = "build")
depends_on("gmake", type = "build")
# configure needs a grep: the tcc-built one (never another version of itself).
depends_on("grep-boot", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("dash", type = "build")

def configure_args(ctx):
    # gcc 16 via the wrapper, explicit glibc triple (no uname). Drop
    # NLS and the PCRE backend (grep -P) so it stays self-contained.
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
        "--disable-perl-regexp",
    ]
