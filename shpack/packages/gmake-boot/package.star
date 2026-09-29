# SPDX-License-Identifier: MIT

"""GNU make 3.82, as the kaem phase builds it (shpack/bootstrap/make-3.82), with
tcc 0.9.27, musl and the kaem-phase tools before it, into the unhashed
$STORE/gmake-boot-3.82. kaem-steps names the step and what it reads: shpack
takes the package as installed by the kaem phase, and Spack's star-recipes
adapter runs the step's kaem.run. No other phase applies."""

homepage = "https://www.gnu.org/software/make/"
license("GPL-3.0-or-later")

version(
    "3.82",
    sha256 = "e2c1a73f179c40c71e2fe8abf8a8a0688b8499538512984da4a76958d0402966",
    url = "https://mirrors.kernel.org/gnu/make/make-3.82.tar.bz2",
)

# the kaem PATH of the step: the seed, then every step before it, in order
depends_on("tcc", type = "build")
depends_on("sandbox", type = "build")
depends_on("patch-shebangs", type = "build")
depends_on("star", type = "build")
