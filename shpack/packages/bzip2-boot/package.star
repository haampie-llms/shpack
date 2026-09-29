# SPDX-License-Identifier: MIT

"""bzip2 1.0.8, as the kaem phase builds it (shpack/bootstrap/bzip2-1.0.8), with
tcc 0.9.27, musl and the kaem-phase tools before it, into the unhashed
$STORE/bzip2-boot-1.0.8. kaem-steps names the step and what it reads: shpack
takes the package as installed by the kaem phase, and Spack's star-recipes
adapter runs the step's kaem.run. No other phase applies."""

homepage = "https://sourceware.org/bzip2/"
license("bzip2-1.0.6")

version(
    "1.0.8",
    sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
    url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz",
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
