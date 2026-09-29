# Spack and package.star

`package.star` is bilingual. It is written in the common subset of Starlark
and Python, so it can be evaluated by two interpreters:
- shpack evaluates it with `star`.
- Spack executes it as Python (`spack.starlark_eval`), in a namespace that
  holds only the protocol's directives and actions.

Over every recipe, version and arch here, both give the same records;
`tests/corpus.sh` produces the ones to compare. `star` is also the dialect
checker, so a recipe that only Python accepts never gets in.

The Spack side is a prototype on the `star-recipes` branch of Spack. It loads
this tree as a Package API v1 repository (`shpack/repo.yaml`).

## Dependency types

The recipes declare Spack's types (`type=`, `("build", "link")` by default),
and both hosts derive a build's environment from them by Spack's rule
(PROTOCOL.md, "Hosts"). The concretizer, though, is told that every edge is
`build`. The bootstrap links two musls, glibc-boot and glibc, and two dashes
into what Spack would make a single unification set, and duplicates of link
dependencies are beyond it, under `duplicates: minimal` and `full` alike.
Declared as build edges, shpack's DAG concretizes (the packages are tagged
`build-tools`). The adapter keeps the recipe's types (`_star_deps`) for PATH,
the compiler wrapper's `-I`/`-L`/rpath and `PKG_CONFIG_PATH`.

## Reuse

shpack records its installs (`.spack/spec.json`, `.spack-db`) as Spack
declares the recipes, so a Spack with this tree registered as the `bootstrap`
repo reuses them. Three things have to agree:
- **Edges are `build`.** A reused node's link or run edge would put its
  target in the root unification set, which only link/run edges of the
  package graph reach (`possible_in_link_run`); the solve would fail and
  Spack would rebuild instead.
- **`build_system` is `generic`.** The adapter declares no build system (the
  plan carries it), so any other value is not one the package has.
- **Every node's package exists in the repo.** A node Spack cannot load is
  not reusable, and neither is anything that depends on it. The kaem-phase
  seeds without a recipe of their own (`tcc`, `dash-boot`, `star`) have
  version-only stubs, which shpack ignores (`buildable=false` in
  `etc/externals`).

## Status

Spack built the full gcc 16 DAG (31 packages) from these recipes. It ran with
shpack's staging and build environment, into a store whose paths have the
same length as shpack's.

- **22 of 31 prefixes are byte-identical** to shpack's, including modes, once
  the hashes in store paths are rewritten. These cover the whole tcc/musl
  tier and binutils-boot0/1, musl, sed, tar, xz, linux-headers, bison, gawk,
  zlib-ng and zstd.
- **9 packages differ, in 83 files.**

## TODO

- **gcc-boot1 (9.5).** `xgcc -print-multi-os-directory` gives `../lib64`
  under Spack and `.` under shpack, so libstdc++ lands in `lib64/`. The
  driver's compiled-in `*multilib` spec differs: shpack's is `. !mabi=lp64;`,
  Spack's is `. !mabi=lp64;.:../lib64 mabi=lp64;`. So genmultilib saw
  aarch64's `MULTILIB_OSDIRNAMES` in one build and not in the other. The
  environments the two hosts construct for this build are identical apart
  from the jobserver fds. Keep both stages (`SHPACK_KEEP_STAGE`,
  `SPACK_STAR_KEEP_STAGE`) and diff `gcc/Makefile` and `s-mlib`.
  gcc 16's 45 differences probably follow from this.
- **gcc-boot0, gcc-boot2.** Only `executable_checksum` in cc1/cc1plus
  differs; the linked code is identical. One of genchecksum's inputs differs:
  the objects, the archives, or `checksum-options`.
- **python 3.8.** The `_sysconfigdata` `.pyc` files differ; they record
  build-time variables.
- **glibc, glibc-boot, dash, libstdcxx-boot1.** One to four files each, not
  looked at yet.
- **Spack.** `resource()` is fetched by the adapter, so `spack mirror`
  doesn't see resources. Class construction relies on the directive queue
  (`DirectiveMeta`), an internal. Parity with shpack needs
  `SPACK_STAR_STAGE_ROOT`, `SPACK_STAR_BASE_ENV` and
  `SPACK_STAR_PATCH_SHEBANGS`; ordinary use would not.
