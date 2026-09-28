# SPDX-License-Identifier: MIT

"""GNU m4 macro processor (gmp's configure hard-requires it)"""

homepage = "https://www.gnu.org/software/m4/"
license("GPL-2.0-or-later")

version(
    "1.4.7",
    sha256 = "a88f3ddaa7c89cf4c34284385be41ca85e9135369c333fdfa232f3bf48223213",
    url = "https://mirrors.kernel.org/gnu/m4/m4-1.4.7.tar.bz2",
)

build_system("makefile")

depends_on("tcc", type = "build")
depends_on("musl@1.1.24")
depends_on("grep-boot", type = "build")
depends_on("dash@0.5.12", type = "build")
