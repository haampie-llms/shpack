# SPDX-License-Identifier: MIT

"""GNU coreutils 9.7 -- the core file/text/shell utilities (ls, cat, cp,
install, env, sort, ...). Built with the final gcc 16 against glibc; distinct
from the coreutils 5.0 seed in the bootstrap base."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.gnu.org/software/coreutils/"
license("GPL-3.0-or-later")

version(
    "9.7",
    sha256 = "e8bb26ad0293f9b5a1fc43fb42ba970e312c66ce92c1b0b16713d7500db251bf",
    url = "https://ftpmirror.gnu.org/coreutils/coreutils-9.7.tar.xz",
)

build_system("autotools")

# compiler-wrapper supplies gcc 16 + glibc; xz unpacks the .tar.xz source. grep/
# sed/awk for configure come in transitively through the gcc-16 closure.
depends_on("compiler-wrapper", type = "build")
depends_on("gmake", type = "build")
depends_on("xz", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("dash", type = "build")

def configure_args(ctx):
    # Explicit glibc triple (no uname/config.guess in the sandbox). --disable-nls
    # (no gettext); the optional selinux/libcap/gmp backends are simply absent
    # from the store, so configure builds without them.
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
    ]
