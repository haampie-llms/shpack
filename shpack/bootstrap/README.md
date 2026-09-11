# shpack/bootstrap -- the kaem-phase package chain

This directory is the *pre-shell* half of the bootstrap: a static,
hand-written chain of kaem scripts that builds everything from the stage0
seed tools up to the first shell (dash), then execs `shpack`. It replaces the
live-bootstrap manifest/configurator/script-generator machinery with
~nothing: the package order is fixed, so the whole "manager" is `start.kaem`.

## Entry

`seed/after.kaem` (the hook stage0-posix execs once the mescc-tools exist)
builds shpack's kaem and execs it, with an EMPTY environment and CWD = `seed/`,
on `start.<arch>.kaem`, a three-line file naming `ARCH`/`ARCH_DIR` that
`include`s the shared `start.kaem`. That driver:

1. `cd ..; ROOT=${PWD}` -- kaem's `PWD` tracks `getcwd`, so the tree's location
   is discovered, never configured;
2. sets the defaults (`STORE`, `DISTFILES`, `BUILDDIR`, `COMMAND`, `SPEC`) and
   `include-optional`s `${ROOT}/shpack.conf` over them;
3. installs the stage0 tools into per-package store prefixes, grows `stack_c`
   and `tcc_cc` (`check-tools.kaem` verifies the latter reproduces its seed);
4. runs the chain, one child kaem per `<name-version>/kaem.run`;
5. `exec`s `${STORE}/dash-0.5.12/bin/sh shpack/bin/shpack ${COMMAND} ${SPEC}`
   with the configuration in the environment.

Nothing is generated on the host and no token is substituted: what a script
needs it takes from kaem variables.

## Conventions

One directory per package, named `<name>-<version>` to match its store
prefix `${STORE}/<name>-<version>` (the kaem phase cannot compute spec hashes;
these prefixes are registered as shpack *externals* in `etc/externals`).

Each directory holds:

- `kaem.run` -- the build script, run by a child `kaem --strict` from
  `start.kaem`. It builds in `${TMPDIR}/build/${pkg}` and installs into
  `${PREFIX}`/`${BINDIR}`.
- `sources.sha256` -- `sha256sum -c` lines (bare file names) pinning the
  upstream tarball(s); `kaem.run` checks them first thing after `cd ${DISTFILES}`.
- package assets (`files/`, `patches/`, `mk/`, `simple-patches/`, the musl
  per-arch trees, ...) referenced as `${PKG}/...`. Some makefiles and patches
  originate from live-bootstrap. A store path a fragment needs at build time
  (`musl-1.1.24/shpack-shell/*.after`) is carried as a `@STORE@` token and
  instantiated in-chain with mescc-tools-extra `replace`.

Environment contract (set in `start.kaem`, inherited by every `kaem.run`):

| var | value |
|---|---|
| `ROOT` | the tree root (parent of `seed/`) |
| `ARCH`, `ARCH_DIR` | `amd64` / `aarch64`, `AMD64` / `AArch64` |
| `STORE` | store root, default `${ROOT}/store` |
| `DISTFILES` | tarballs, default `${ROOT}/distfiles` |
| `BUILDDIR`, `TMPDIR` | scratch, default `${ROOT}/tmp` |
| `SEEDDIR`, `MESR` | `${ROOT}/seed` (M2libc), `${ROOT}/vendor/mes-replacement` |
| `BOOT` | this directory |
| `LIBC_PREFIX`/`LIBDIR`/`INCDIR` | the musl store prefix and its lib/include |
| `pkg`, `PKG` | `<name-version>`, `${BOOT}/${pkg}` |
| `PREFIX`, `BINDIR` | `${STORE}/${pkg}`, `${PREFIX}/bin` |

`PATH` starts as the seed prefixes and grows one `${STORE}/<pkg>/bin` prepend
per package, newest first -- the same composition rule shpack uses later; its
final value is handed to shpack as `BASEPATH`.

The `kaem.run` command sequences are dictated by what each package needs to
compile under tcc/musl (object lists, `-D` macros, boot stages); the
rationale lives in the comments of each script.

## Why this is not under `shpack/packages/`

shpack hashes a recipe directory's full contents into the spec hash of that
package (and, Merkle-style, of everything depending on it). Kaem-phase
assets are not inputs to the shell-phase recipes, so keeping them here
avoids a kaem.run comment edit rebuilding the entire gcc closure. The
shell-phase handoff sees these packages only as externals with fixed
prefixes.
