# SPDX-License-Identifier: MIT

"""GNU grep 2.4, the tiny tcc-built grep that scripts the early chain's
configure/Makefiles (every GNU configure needs grep), and the grep that the
modern grep builds with."""

homepage = "https://www.gnu.org/software/grep/"
license("GPL-2.0-or-later")

# Grown by tcc against the kaem-external musl 1.1.24, driven by a replacement
# files/Makefile (grep 2.4's own configure needs tools we lack here).
version(
    "2.4",
    sha256 = "a32032bab36208509466654df12f507600dfe0313feebbcd218c32a70bf72a16",
    url = "https://mirrors.kernel.org/gnu/grep/grep-2.4.tar.gz",
)

build_system("makefile")

depends_on("tcc", type = ("build", "link"))
depends_on("dash-boot", type = "build")
