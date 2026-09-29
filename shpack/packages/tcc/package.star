# SPDX-License-Identifier: MIT

"""The seed: the stage0-posix seed grown to tcc 0.9.27 and musl 1.1.24, the
kaem chain of shpack/bootstrap/start.kaem up to COMMAND=seed, in one prefix
($STORE/tcc-0.9.27). tcc 0.9.26 installs its libc into musl's prefix, musl is
rebuilt in place and tcc 0.9.27 bakes that prefix in, so they are one package:
musl and tcc 0.9.27 are the prefix itself (bin/tcc, lib/, include/), and the
tools they were grown with sit in sub-prefixes (seed.path). kaem-steps names
the step: shpack takes it as installed by the kaem phase, and Spack's
star-recipes adapter runs the seed. What depends on it for "link" gets musl."""

homepage = "https://bellard.org/tcc/"
license("LGPL-2.1-or-later AND MIT")

version(
    "0.9.27",
    sha256 = "de23af78fca90ce32dff2dd45b3432b2334740bb9bb7b05bf60fdbfc396ceb9c",
    url = "https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27.tar.bz2",
)
resource(
    url = "https://lilypond.org/janneke/tcc/tcc-0.9.26-1147-gee75a10c.tar.gz",
    sha256 = "6b8cbd0a5fed0636d4f0f763a603247bc1935e206e1cc5bda6a2818bab6e819f",
    fname = "tcc-0.9.26.tar.gz",
)
resource(
    url = "https://www.musl-libc.org/releases/musl-1.1.24.tar.gz",
    sha256 = "1370c9a812b2cf2a7d92802510cca0058cc37e66a7bedd70051f0a34015022a3",
    fname = "musl-1.1.24.tar.gz",
)
