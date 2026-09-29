# SPDX-License-Identifier: MIT

"""GNU sed 4.0.9, as the kaem phase builds it (shpack/bootstrap/sed-4.0.9), with
tcc 0.9.27, musl and the kaem-phase tools before it, into the unhashed
$STORE/sed-boot-4.0.9. kaem-steps names the step and what it reads: shpack
takes the package as installed by the kaem phase, and Spack's star-recipes
adapter runs the step's kaem.run. No other phase applies."""

homepage = "https://www.gnu.org/software/sed/"
license("GPL-2.0-or-later")

version(
    "4.0.9",
    sha256 = "c365874794187f8444e5d22998cd5888ffa47f36def4b77517a808dec27c0600",
    url = "https://mirrors.kernel.org/gnu/sed/sed-4.0.9.tar.gz",
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
