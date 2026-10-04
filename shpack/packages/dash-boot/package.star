# SPDX-License-Identifier: MIT

"""dash 0.5.12, the first shell, as the kaem phase builds it
(shpack/bootstrap/dash-0.5.12), with tcc 0.9.27, musl and the kaem-phase tools
before it, into the unhashed $STORE/dash-boot-0.5.12. kaem-steps names the step
and what it reads: shpack takes the package as installed by the kaem phase, and
Spack's star-recipes adapter runs the step's kaem.run. No other phase applies."""

homepage = "http://gondor.apana.org.au/~herbert/dash/"
license("BSD-3-Clause")

version(
    "0.5.12",
    sha256 = "6a474ac46e8b0b32916c4c60df694c82058d3297d8b385b74508030ca4a8f28a",
    url = "http://gondor.apana.org.au/~herbert/dash/files/dash-0.5.12.tar.gz",
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
depends_on("coreutils-boot", type = "build")
depends_on("shpack-builder", type = "build")
