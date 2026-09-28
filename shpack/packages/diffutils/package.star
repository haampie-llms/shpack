# SPDX-License-Identifier: MIT

"""GNU diff and cmp (configure scripts and gcc's build use them)"""

homepage = "https://www.gnu.org/software/diffutils/"
license("GPL-2.0-or-later")

version(
    "2.7",
    sha256 = "d5f2489c4056a31528e3ada4adacc23d498532b0af1a980f2f76158162b139d6",
    url = "https://mirrors.kernel.org/gnu/diffutils/diffutils-2.7.tar.gz",
)

build_system("makefile")

depends_on("tcc", type = "build")
depends_on("musl@1.1.24")
depends_on("grep-boot", type = "build")
depends_on("dash@0.5.12", type = "build")
