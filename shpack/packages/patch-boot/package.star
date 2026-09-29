# SPDX-License-Identifier: MIT

"""GNU patch 2.5.9, as the kaem phase builds it (shpack/bootstrap/patch-2.5.9),
with tcc 0.9.27, musl and the kaem-phase tools before it, into the unhashed
$STORE/patch-boot-2.5.9. kaem-steps names the step and what it reads: shpack
takes the package as installed by the kaem phase, and Spack's star-recipes
adapter runs the step's kaem.run. No other phase applies."""

homepage = "https://savannah.gnu.org/projects/patch/"
license("GPL-2.0-or-later")

version(
    "2.5.9",
    sha256 = "ecb5c6469d732bcf01d6ec1afe9e64f1668caba5bfdb103c28d7f537ba3cdb8a",
    url = "https://mirrors.kernel.org/gnu/patch/patch-2.5.9.tar.gz",
)

# the kaem PATH of the step: the seed, then every step before it, in order
depends_on("tcc", type = "build")
depends_on("sandbox", type = "build")
depends_on("patch-shebangs", type = "build")
depends_on("star", type = "build")
depends_on("gmake-boot", type = "build")
