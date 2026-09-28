# SPDX-License-Identifier: MIT

"""GNU awk 3.0.4, the tiny tcc-built awk that scripts the early chain's
configure/Makefiles, and the awk that the modern gawk builds with."""

load("//build_systems/lib.star", "replace_bin_sh")

homepage = "https://www.gnu.org/software/gawk/"
license("GPL-2.0-or-later")

# Grown by tcc against musl 1.1.24, driven by a replacement files/Makefile (its
# own configure needs tools we lack this early).
version(
    "3.0.4",
    sha256 = "5cc35def1ff4375a8b9a98c2ff79e95e80987d24f0d42fdbb7b7039b3ddb3fb0",
    url = "https://mirrors.kernel.org/gnu/gawk/gawk-3.0.4.tar.gz",
)

build_system("makefile")

# tcc + musl 1.1.24, seed make on PATH (no gmake dep).
depends_on("tcc", type = "build")
depends_on("musl@1.1.24")
depends_on("grep-boot", type = "build")
# replace_bin_sh (below) compiles the shell path into the binary.
depends_on("dash@0.5.12", type = "build")

def edit(ctx):
    # gawk's system()/getline/print-to-cmd execl a hardcoded "/bin/sh", which the
    # sandbox denies. Repoint at the store shell.
    return [
        copy(ctx.package_dir + "/files/Makefile", "./Makefile"),
        replace_bin_sh(ctx, ["builtin.c", "io.c"]),
    ]
