# SPDX-License-Identifier: MIT

"""The kaem phase's dash (shpack/bootstrap/dash-0.5.12) under a name of its
own: the build shell of the dash recipe, which cannot depend on dash. Not
buildable here (etc/externals): this stub only names the package for Spack."""

homepage = "http://gondor.apana.org.au/~herbert/dash/"
license("BSD-3-Clause")

version("0.5.12")
