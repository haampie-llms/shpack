# SPDX-License-Identifier: MIT

"""sandbox, shpack's Landlock launcher for build steps, as the kaem phase builds it (shpack/bootstrap/sandbox-1.0), with tcc 0.9.27
and musl and the kaem-phase tools before it, all in one prefix
($STORE/sandbox-1.0). kaem-steps names the step: shpack takes it as installed by
the kaem phase, and Spack's star-recipes adapter runs the step's kaem.run.
No other phase applies."""

license("MIT")

version("1.0")

# the kaem PATH of the step: the seed, then every step before it, in order
depends_on("tcc", type = "build")
