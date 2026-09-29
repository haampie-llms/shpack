# SPDX-License-Identifier: MIT

"""shpack's builder, shpack/bin/shpack-build and the libraries it sources, as
the kaem phase installs it (shpack/bootstrap/shpack-builder-1.0) into the
unhashed $STORE/shpack-builder-1.0. Every host builds a node by running it
from the store, so its content is in every hash, by way of dash-boot.
kaem-steps names the step and what it reads: shpack takes the package as
installed by the kaem phase, and Spack's star-recipes adapter runs the step's
kaem.run. No other phase applies."""

license("MIT")

version("1.0")

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
