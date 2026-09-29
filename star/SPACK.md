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
`build-tools`). The adapter keeps the recipe's types (`StarPackage.declared_edges`) for PATH,
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
  not reusable, and neither is anything that depends on it. The kaem phase's
  packages are recipes (`kaem-steps`), so there are no externals.

## Same hashes

shpack's node hash is Spack's DAG hash (the base32 SHA-1 of the node's JSON as
`Spec.to_node_dict` makes it), and its package hash is Spack's `content_hash`
over the adapter's `StarPackage.package_text`: shpack's package text (`package_text` in
lib/concretize.star), which covers every file in the package directory, the
sources, the evaluator and every loaded module. Every Starlark package
requires `os=shpack`, an OS the adapter registers on the host platform, as
shpack records it. So `spack spec --fresh gcc-boot0` gives shpack's hashes,
and Spack installs where shpack does.

## The kaem phase

A version listed in its recipe's `kaem-steps` is built by the adapter the way
shpack's kaem phase builds it (`_kaem_install`): the seed, `tcc@0.9.27`, by the
stage0 seed itself on a copy of the tree (`COMMAND=seed`), any other step by
its `kaem.run` under the kaem phase's environment contract, with the step's
archives unexpanded in a DISTFILES directory and PATH composed as start.kaem
composes it (the step, the steps before it newest first, `seed.path`). They
install unhashed, by the `{name}-{version}` projections of the tree's
`spack.yaml`.

## Shell-phase builds

Any other version is built by shpack's builder, `shpack-builder` in the store
(a kaem step, which every DAG reaches through dash-boot), as shpack builds it:
the adapter writes the concrete spec out as the builder's state files
(`spec/<id>/` of the node and its closure, PROTOCOL.md, Hosts) and runs
`dash-boot/bin/sh shpack-builder/bin/shpack-build ID`. The build's PATH, its
base, the build shell, staging, patching, the plan (by `star`, from the DAG)
and running it are the builder's, so the two hosts share them rather than
agree on them.

## Staging and the sandbox

The tree is a Spack environment (`spack.yaml`): the `bootstrap` repository
alone, the projections, and the new installer with its Landlock sandbox on.

    spack -e . install --add gcc-boot0

Spack fetches and checks every archive (version and `resource()`, all left
unexpanded), so mirrors see them. Staging then copies into the stage what the
build reads, before the sandbox applies: the archives under their names, the
recipe directory and the modules it loads, a kaem step's inputs, and
`seed.path`, i.e. what the package hash covers. The build, sandboxed, reads
only that copy and its dependencies' prefixes, and writes only its stage and
prefix: it unpacks and patches with the tools on its PATH (no shell), finds
`patch-shebangs` there, and evaluates the plan from the copied recipe. Spack's
`get_user()` is memoized, so the stage path resolves once `/etc/passwd` is
out of reach. `spack install --keep-stage` keeps the stage, with the plan's
environment in `shpack/env`.

## Status

Up to gcc-boot0 (23 packages, from the stage0 seed), `spack -e . install`
into an empty store, sandboxed, gives the prefixes the single-execve bootstrap
gives, byte for byte (`.spack/` aside). Before the hashes were shared, Spack
built the full gcc 16 DAG (31 packages) from these recipes, into a store whose
paths had the same length as shpack's:

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
  `spack install --keep-stage`) and diff `gcc/Makefile` and `s-mlib`.
  gcc 16's 45 differences probably follow from this.
- **gcc-boot2.** Only `executable_checksum` in cc1/cc1plus differed (as in
  gcc-boot0, which is identical since the builds share hashes and prefixes);
  check again.
- **python 3.8.** The `_sysconfigdata` `.pyc` files differ; they record
  build-time variables.
- **glibc, glibc-boot, dash, libstdcxx-boot1.** One to four files each, not
  looked at yet.
- **Spack.** Class construction relies on the directive queue
  (`DirectiveMeta`), an internal.
