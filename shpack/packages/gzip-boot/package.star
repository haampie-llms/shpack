# SPDX-License-Identifier: MIT

"""gzip 1.2.4, as the kaem phase builds it (shpack/bootstrap/gzip-1.2.4), with tcc 0.9.27
and musl and the kaem-phase tools before it, all in one prefix
($STORE/gzip-boot-1.2.4). kaem-steps names the step: shpack takes it as installed by
the kaem phase, and Spack's star-recipes adapter runs the step's kaem.run.
No other phase applies."""

homepage = "https://www.gnu.org/software/gzip/"
license("GPL-2.0-or-later")

version(
    "1.2.4",
    sha256 = "1ca41818a23c9c59ef1d5e1d00c0d5eaa2285d931c0fb059637d7c0cc02ad967",
    url = "https://mirrors.kernel.org/gnu/gzip/gzip-1.2.4.tar.gz",
)

# the kaem PATH of the step: the seed, then every step before it, in order
depends_on("tcc", type = "build")
depends_on("sandbox", type = "build")
depends_on("patch-shebangs", type = "build")
depends_on("star", type = "build")
depends_on("gmake-boot", type = "build")
depends_on("patch-boot", type = "build")
