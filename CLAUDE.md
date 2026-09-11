# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

shpack is a bootstrappable package manager written in POSIX shell. Starting from the stage0-posix binary seed, it builds a full GCC/glibc/binutils toolchain (and optionally Spack) from checksummed sources. `README.md` has the design in detail; this file covers what you need to work on it.

## Commands

```sh
./fetch-distfiles.sh                 # download + sha256-verify all sources into distfiles/

./shpack/tests/run.sh                # full test suite (host, under dash; no chroot/sandbox)
dash shpack/tests/t-hash.sh          # one test; exit status is the result
TEST_SH=bash ./shpack/tests/run.sh   # run the suite under another shell
                                     # per-test logs: /tmp/shpack-test-t-*.log

cd seed && exec bootstrap-seeds/POSIX/AMD64/kaem-optional-seed kaem.amd64
                                     # THE bootstrap: base into ./store, then `shpack install gcc`
./run-local.sh [--arch aarch64]      # the same line, arch picked for you
./run-rootfs.sh [--arch aarch64]     # the same line inside a bwrap namespace holding only this tree
cp shpack.conf.example shpack.conf   # STORE/DISTFILES/BUILDDIR/JOBS and COMMAND/SPEC
                                     #   COMMAND=spec SPEC=gcc -> concretize + print the DAG, no build
                                     #   COMMAND=shell         -> interactive store dash, `shpack` by name
```

There is no host-side staging and no `shpack` binary on the host: the whole kickoff is that one exec (see `seed/after.kaem` → `shpack/bootstrap/start.<arch>.kaem` → `start.kaem`). Shell-phase state (`$SHPACK_VAR`) is `$BUILDDIR/shpack` (default `./tmp/shpack`): per-package logs in `logs/<id>.log`, the generated `dag.mk`, and `spec/<id>/manifest` (the exact hash input of a node). An installed prefix keeps its log at `<prefix>/.shpack/build.log`. `shpack env <name>` prints a node's composed PATH/PREFIX. Re-running always rebuilds the kaem-phase base (a few minutes, into the same prefixes) and then only missing store prefixes. One run at a time: store and state are shared on disk.

## Two phases

1. **Kaem phase** (`shpack/bootstrap/start.kaem`, included by `start.<arch>.kaem`): a fixed, hand-written chain: stage0 seed → tcc 0.9.26 (via `vendor/mes-replacement`) + musl → tcc 0.9.27 → sandbox, patch-shebangs → make, patch, gzip, tar, sed, bzip2, coreutils → dash. Each `<name>-<version>/kaem.run` installs to an unhashed `$STORE/<name>-<version>`; these prefixes are registered (store-relative) in `shpack/etc/externals`. The driver runs on shpack's own kaem with an **empty environment**, does `cd ..; ROOT=${PWD}`, sets defaults, `include-optional`s `$ROOT/shpack.conf`, and ends by `exec`ing the store dash on `bin/shpack $COMMAND $SPEC` with `ROOT STORE DISTFILES BUILDDIR ARCH BASEPATH [JOBS]` exported.
2. **Shell phase** (`shpack/bin/shpack`, `shpack/lib/`, `shpack/packages/`): the actual package manager, running under the bootstrap dash. Its configuration **is the environment** (the variables above); `etc/config` only derives `CONFIG_SHELL`, `SANDBOX`, `PATCH_SHEBANGS`, `SHPACK_BOOTSTRAP_MAKE` from `$STORE`, each overridable (the test fixture sets `SANDBOX=` and `PATCH_SHEBANGS=` empty).

`seed/` is a pristine vendored copy of stage0-posix (`seed/UPSTREAM` records the tag/commits; no submodules). The only file of ours in it is `seed/after.kaem`, which compiles `vendor/kaem` (mescc-tools kaem + a `PWD` that tracks `getcwd`, `include`/`include-optional` builtins, the no-malloc optimization) with M2-Planet in a scratch copy of the `mescc-tools/Kaem` layout, then execs it `--init-mode` (clean env). The seed-phase scripts are cwd-relative and the seed interpreters have no `cd`, hence exec from inside `seed/`. Nothing is generated or substituted on the host: `@STORE@` in `bootstrap/musl-1.1.24/shpack-shell/*.after` is instantiated in-chain with mescc-tools-extra `replace`; `sources.sha256` files list bare names, verified after `cd ${DISTFILES}`.

## Shell-phase architecture

- `lib/repo.sh`: recipe directives (`version`, `depends_on`, `patch`, `resource`, `build_system`, `parallel`, `build_directory`, ...) don't interpret anything; they just append lines to state files under `$VAR/recipe/<name>/`. Concretization loads recipes in a subshell (hooks are thrown away). `build-one` loads them in-process to keep the hooks, then `recipe_disarm` unsets the directive functions so `patch` and friends are the real commands again.
- `lib/concretize.sh`: `resolve` → `visit` (recursive DFS building `$VAR/spec/<id>/`) → `emit_index` → `emit_dagmk`. `shpack install` then runs `dag.mk` with make. If the DAG contains `SHPACK_BOOTSTRAP_MAKE` (gmake@4.4.1), that node is built first, serially, under make 3.82, and the rest runs `-j$JOBS` under the new make's jobserver.
- `lib/builder.sh` (`build-one`): fetch → stage → patch → patch-shebangs → `setup_build_environment` → build-system phases → finalize. Each phase is either a recipe function of the same name or `default_<phase>` from `lib/build_systems/{generic,makefile,autotools}.sh`.
- `lib/spec.sh`: hashing helpers. The node hash is sha256 over a manifest of: recipe name/version, arch, source sha256s, **every file in `packages/<name>/`** (dotfiles skipped), and direct deps' name/version/hash, truncated to 7 hex digits. Externals hash only as `external name version`, never their prefix, so hashes don't depend on where the store lives.

Resolution rules:
- The **first declared** `version` wins for a bare name, so list the preferred version first. There is no version comparison.
- A recipe always beats an external for a bare name. Externals are the fallback for names with no recipe (`tcc`, `dash@0.5.12`) or for exact `@version` pins.
- `when=VER` on `depends_on`, `patch`, `resource` and `build_system` is an exact string match against this recipe's version.
- Node ids are `name-version`, and versions can contain dashes. Never split an id back into name and version; read `spec/<id>/name` instead.

## Hard constraints

- **Tool budget for `bin/` and `lib/`**: this code runs under dash 0.5.12, coreutils 5.0, sed 4.0.9, make 3.82 and the stage0 `sha256sum`. `grep awk gawk find xargs expr cut tac mktemp` must not appear in them; `tests/t-lint.sh` enforces this. Use `while read`, globs, `case`, and parameter expansion instead (see `walk_files`, `reverse_lines`, `member_line` in `spec.sh`). Emitted `dag.mk` must work with make 3.82. Host scripts (`run-*.sh`, `fetch-distfiles.sh`, tests) are not bound by this. The kaem phase is stricter still: `start.kaem`, `after.kaem` and every `kaem.run` have only kaem's builtins (`cd`, `if match ...; then`, `include`, variables, no string ops) and the mescc-tools (`mkdir cp chmod rm catm match replace sha256sum ungz untar ...`); `vendor/kaem` must stay within the M2-Planet C subset.
- **`shpack.conf` is read by both kaem and dash**, so keep the format to `KEY=VALUE` lines, `${VAR}` references and `#` comments: no quotes, no spaces, no shell syntax.
- **Every recipe needs a direct `depends_on dash`** (`dash@0.5.12` for packages below glibc, plain `dash` for the glibc dash above it). The builder takes `$sh` from it and dies without one; `t-lint.sh` checks this too.
- **No `/bin/sh` anywhere.** Builds run inside a Landlock sandbox (`sandbox-1.0`) that can read only the store, the shpack tree, the repo, distfiles and `etc`, and write only its own prefix plus `$VAR`. `TMPDIR=$VAR` for the same reason. `SHELL=$sh` is forced through `MAKEFLAGS`. Hardcoded `/bin/sh` string literals in sources go through `replace_bin_sh` in the recipe's `edit()` phase. Shebangs are rewritten by `patch-shebangs`. The test fixture leaves `SANDBOX` and `PATCH_SHEBANGS` unset, so sandbox problems only show up in real launcher builds.
- **Hash scope**: any edit to a file in `packages/<name>/`, including comments, changes that package's hash and the hash of everything above it. Kaem-phase assets live in `shpack/bootstrap/` rather than `packages/` so they stay out of shell-phase hashes.

## Recipe conventions

- Argument hooks (`configure_args`, `build_args`, `build_targets`, `install_targets`) print **one argument per line**, e.g. `printf '%s\n' 'AR=tcc -ar'`.
- Source mutation (sed edits, `replace_bin_sh`, relocating resources) goes in `edit()`. `setup_build_environment` should only set environment variables.
- Inside a recipe that defines `install()`, call the coreutils binary as `command install`.
- Recipes can use: `name version id package_dir stage_dir source_dir sh makejobs file_prefix_map debug_prefix_map`, the helpers `prefix_of <dep>`, `triple [gnu|musl] [unknown]` and `replace_bin_sh`, plus `PREFIX ARCH JOBS`. `ARCH` is `amd64` or `aarch64`.
- Use `$makejobs`, not `-j$JOBS`: builds inherit the dag.mk jobserver, and `parallel false` turns `$makejobs` into `-j1`.
- Packages built by the final gcc depend on `compiler-wrapper`. It injects `-I`/`-L`/`-rpath` for direct deps and `-ffile-prefix-map`.

**Reproducibility** is an active focus (see recent commits). The builder already sets `SOURCE_DATE_EPOCH=0`, remaps the stage dir with `-ffile-prefix-map`, runs `configure` by relative path, and deletes `.la` files. tcc- and gcc-4.7-built stages drop `-g` (e.g. `CFLAGS=-O2`) so the build cwd doesn't leak into binaries. To diff two builds, run `run-rootfs.sh` (bwrap, tree bound at its own path) against a `run-local.sh` build, or vary `BUILDDIR` in `shpack.conf` while keeping `STORE`.

## Bootstrap (kaem-phase) conventions

- Each step has `kaem.run`, `sources.sha256` (bare file names, checked after `cd ${DISTFILES}`) and assets referenced as `${PKG}/...`. The env contract is in `shpack/bootstrap/README.md`.
- `fetch-distfiles.sh` builds its manifest from the tree: recipe `version`/`resource` lines, and for bootstrap steps, `sources.sha256` paired with a `# Source: URL [FNAME]` comment in the same `kaem.run`. A new bootstrap distfile needs both.
- The kaem chain has no GNU `patch`. Source edits for tcc and musl are `simple-patches/*.{before,after}` fragments applied by `simple-patch` (first exact match). They are **generated** from the canonical `patches/*.patch` by `regen.py` (musl also has `regen.sh` for its generated headers and sysinclude tars). Edit the `.patch` files and regenerate; don't hand-edit fragments.
- The only committed prebuilt binaries are `vendor/mes-replacement/tcc_cc.<arch>.sl64`, pinned by `.sha256` and re-derived and checked by `check-tools.kaem`.
