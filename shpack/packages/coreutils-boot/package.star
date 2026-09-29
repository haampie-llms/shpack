# SPDX-License-Identifier: MIT

"""GNU coreutils 5.0, as the kaem phase builds it
(shpack/bootstrap/coreutils-5.0), with tcc 0.9.27, musl and the kaem-phase
tools before it, into the unhashed $STORE/coreutils-boot-5.0. kaem-steps names
the step and what it reads: shpack takes the package as installed by the kaem
phase, and Spack's star-recipes adapter runs the step's kaem.run. No other
phase applies."""

homepage = "https://www.gnu.org/software/coreutils/"
license("GPL-2.0-or-later")

version(
    "5.0",
    sha256 = "c25b36b8af6e0ad2a875daf4d6196bd0df28a62be7dd252e5f99a4d5d7288d95",
    url = "https://mirrors.kernel.org/gnu/coreutils/coreutils-5.0.tar.bz2",
)

# the kaem PATH of the step: the seed, then every step before it, in order
depends_on("tcc", type = "build")
depends_on("sandbox", type = "build")
depends_on("patch-shebangs", type = "build")
depends_on("star", type = "build")
depends_on("gmake-boot", type = "build")
depends_on("patch-boot", type = "build")
depends_on("gzip-boot", type = "build")
depends_on("tar-boot", type = "build")
depends_on("sed-boot", type = "build")
depends_on("bzip2-boot", type = "build")
