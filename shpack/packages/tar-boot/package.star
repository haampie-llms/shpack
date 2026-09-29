# SPDX-License-Identifier: MIT

"""GNU tar 1.12, as the kaem phase builds it (shpack/bootstrap/tar-1.12), with tcc 0.9.27
and musl and the kaem-phase tools before it, all in one prefix
($STORE/tar-boot-1.12). kaem-steps names the step: shpack takes it as installed by
the kaem phase, and Spack's star-recipes adapter runs the step's kaem.run.
No other phase applies."""

homepage = "https://www.gnu.org/software/tar/"
license("GPL-2.0-or-later")

version(
    "1.12",
    sha256 = "c6c37e888b136ccefab903c51149f4b7bd659d69d4aea21245f61053a57aa60a",
    url = "https://mirrors.kernel.org/gnu/tar/tar-1.12.tar.gz",
)

# the kaem PATH of the step: the seed, then every step before it, in order
depends_on("tcc", type = "build")
depends_on("sandbox", type = "build")
depends_on("patch-shebangs", type = "build")
depends_on("star", type = "build")
depends_on("gmake-boot", type = "build")
depends_on("patch-boot", type = "build")
depends_on("gzip-boot", type = "build")
