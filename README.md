# shpack

`shpack` is a fast, bootstrappable package manager for Linux. It is capable of building a complete modern compiler toolchain (GCC 16, glibc 2.43, binutils 2.46) from sources, starting from a few hundred bytes of trusted machine code (from [stage0-posix][3]). The first C/C++ compiler, GCC 4.7, comes up in about **2 minutes 30 seconds**, and the full dynamically linked toolchain finishes in **15 to 30 minutes**[^fast][^bench] total. It runs rootless, needs no user namespaces, and the whole kickoff is a single `exec` of the stage0 seed: no shell, coreutils, `sudo` or `chroot` on the host.

The build itself trusts only a single binary seed. Everything else is compiled from checksummed sources. It bootstraps a basic shell first, then increasingly capable C compilers and libraries, and finally the complete toolchain using a new bootstrapping path where the TinyCC C compiler with musl libc is built straight out of stage0-posix via [MES replacement][1]. It targets `x86_64` and `AArch64` natively from the start, which matters on modern systems where 32-bit support (x86, arm32) may be disabled in the kernel or missing from the CPU (e.g. Apple Silicon).

`shpack` borrows ideas from [Spack][4], Nix, and Guix, such as immutable store prefixes and Merkle-hashed dependency graphs. It is no coincidence that the [recipes][5] resemble Spack's (they are Starlark, evaluated by [`star`](star/), a small interpreter the bootstrap builds with its first C compiler): one motivation for the project is to [bootstrap the Spack package manager itself](#shpack-install-spack). Thanks to Guix and [live-bootstrap][2] for showing that a full bootstrap is possible, and to [MES replacement][1] for making it fast.

## Quick start

### Setup

Clone the repository (stage0-posix is vendored, no submodules) and download the
package sources once:

```sh
git clone --depth=1 https://github.com/haampie/shpack.git
cd shpack
./fetch-distfiles.sh     # download the sources of every package into distfiles/
```

### Run

The whole bootstrap is one `exec` of the stage0 seed from inside `seed/`:

```sh
cd seed && exec bootstrap-seeds/POSIX/AMD64/kaem-optional-seed kaem.amd64    # or AArch64 / kaem.aarch64
```

That is the complete contract: a directory tree and the kernel. The seed grows the
stage0 tools, `seed/after.kaem` builds shpack's `kaem`, and
`shpack/bootstrap/start.kaem` derives every path from where the tree is, reads
`./shpack.conf`, builds the kaem-phase base (up through `dash`) into `./store` and
execs `shpack install gcc` on the store shell. Two convenience wrappers spell that
line out for you:

- `./run-local.sh [--arch amd64|aarch64]` -- runs it as-is on the host.
- `./run-rootfs.sh [--arch ...]` -- runs it inside a rootless `bwrap`[^bwrap]
  namespace that contains nothing but this tree, `/dev` and `/proc`. Needs
  unprivileged user namespaces (Debian and Ubuntu restrict them; enable with
  `sudo sysctl -w kernel.unprivileged_userns_clone=1` on Debian,
  `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` on Ubuntu 24.04+).
  Since the tree is bound at its own path, the store it produces should be
  byte-identical to a host run's: that is what it is for.

```console
$ ./run-local.sh
...
[+] 4cxpi2c gcc@16.1.0 /home/you/shpack/store/linux-aarch64/gcc-16.1.0-4cxpi2cz2dru4e55iurmmmvmpvcylvxd
$ store/linux-aarch64/gcc-16.1.0-4cxpi2cz2dru4e55iurmmmvmpvcylvxd/bin/g++ hello.cc -o hello && ./hello
hello world
```

Building without a chroot might sound "nonreproducible", but every package build
is confined by a [Linux Landlock][7] sandbox, itself bootstrapped early on, and
the packages built before it exist do not use system paths.
See [Sandboxing](#sandboxing).

### Configuration

Everything configurable lives in `./shpack.conf` (copy `shpack.conf.example`):
`STORE`, `DISTFILES`, `BUILDDIR`, `JOBS`, and what to run once the base is
built (`COMMAND`/`SPEC`, default `install gcc`). It is a plain `KEY=VALUE` file
that both `kaem` and `sh` read; `${ROOT}` is the tree root. No environment
variables are involved on the host side.

### Running interactively

`COMMAND=shell` in `shpack.conf` drops you into the bootstrapped `dash` once the
base is built, with the store on `PATH` and `shpack` available by name:

```sh
shpack$ shpack install xz
```

Re-running the bootstrap rebuilds the kaem-phase base (a few minutes) and then
only what the store lacks: installed prefixes are never rebuilt. One run at a
time -- store and state are shared on disk.

### What `shpack install gcc` resolves

`shpack install gcc` resolves the dependency graph and builds it:

```
...
==> shpack install gcc
4cxpi2c  [    ]  gcc@16.1.0
pzr5lqm  [b   ]    gcc-boot-wrapper@16.1.0
xhecsx6  [b r ]      gcc-boot2@16.1.0
6elkxfh  [b   ]        gmake@4.4.1
avjqpsa  [b   ]          tcc@0.9.27 (external)
twm6xh5  [bl  ]          musl@1.1.24 (external)
rgir4f4  [b   ]          grep-boot@2.4
egnjari  [b   ]            dash@0.5.12 (external)
h6rz6lz  [b   ]          gawk-boot@3.0.4
3zx5q53  [b   ]        diffutils@2.7
y657jx4  [b   ]        findutils@4.2.33
e3jq2gw  [b   ]        gcc-boot1@9.5.0
f7v3s67  [b   ]          gcc-boot0@4.7-2013.11
jli4iow  [b r ]            binutils-boot0@2.30-musl
xdl3pl6  [b   ]              m4@1.4.7
kfnhlob  [bl  ]            gmp@4.3.2
q3s75ka  [bl  ]            mpfr@2.4.2
fqxbfki  [bl  ]            mpc@1.0.3
fzrl2hi  [bl  ]          musl@1.2.5
4vp2eyy  [bl  ]            linux-headers@6.9.1
cskrdly  [b   ]              sed@4.9-musl
kfnzq2q  [b   ]                xz@5.2.5-musl
p562sdc  [b   ]          tar@1.35-musl
iw26mff  [b r ]        binutils-boot1@2.46.0-musl
x67vjgi  [b   ]          gawk@5.3.1
hvkz32y  [bl  ]      glibc@2.43
d4senl5  [b   ]        python@3.8.20
u64baoj  [b   ]        bison@3.8.2
7gv2qwp  [b   ]        dash@0.5.13.4
fbazrop  [bl  ]          glibc@2.43-boot
f7yhxh6  [b   ]          dash-boot@0.5.12 (external)
k3bqbga  [b r ]    binutils@2.46.0
k3lar2d  [bl  ]      libstdcxx-boot1@16.1.0
o5c4buc  [bl  ]      zlib-ng@2.3.3-boot
c7xtxe4  [bl  ]      zstd@1.5.7-boot
```

The column in brackets is the type of the dependency edge, as `spack spec -t`
prints it: `b`uild, `l`ink, `r`un. The `(external)` nodes are part of the
initial bootstrapping phase. All installed
packages are put into unique prefixes `$STORE/<name>-<version>[-<hash>]`.

### `shpack install spack`

`shpack install spack` continues past the toolchain and builds [Spack][4] 1.2.0
with its runtime: CPython 3.14 (including the `_ssl`, `_ctypes`, `zlib` and
`_bz2`/`_lzma`/`_zstd` modules), the clingo solver, and supporting tools such as
`git` and `curl`. It resolves and builds the same way as `gcc`, into its own
store prefix.

## Scope and trust

By design, `shpack` bootstraps *on top of a running Linux*: the build does syscalls (`execve` and friends), so it depends on the kernel's ABI, and on whatever `exec`s the seed with the tree as its working directory (a shell, an init, a script -- nothing of it is used afterwards). This is a deliberate scope, not full bare-metal trustlessness -- for that you would boot into the bootstrap and run it directly on hardware. What `shpack` aims for instead is reproducibility: the same seed and sources should yield the same toolchain across different Linux machines, so a [Thompson-style][6] compromise would have to be present on *every* host you compare to go unnoticed. `shpack` also trusts the generated files that upstream ships in release tarballs, including `configure` scripts and pre-generated source files. live-bootstrap takes the stricter path and rebuilds those artifacts too; `shpack` makes the other tradeoff deliberately, optimizing for a modern, real-world toolchain that bootstraps quickly and keeping the dependency set small -- regenerating those artifacts would otherwise pull flex, bison, autotools and texinfo into the chain.

---

# How it works

`shpack` is written entirely in POSIX shell, so it runs on an early `dash`, `make`,
and minimal coreutils; it can take over as soon as the first real shell exists. Its
simple dependency resolver emits a `Makefile`, so independent packages build in
parallel under a single `make` jobserver. The recipes themselves are Starlark,
evaluated by `star` ([star/](star/)), a small C interpreter the kaem phase
builds with its first tcc, right after the compiler itself.

Paths in this section are relative to [shpack/](shpack/).

## Kickoff

Before any shell exists the bootstrap is driven by `kaem`, stage0-posix's
minimal script runner. `seed/` is a vendored copy of stage0-posix; its seed
scripts are cwd-relative and the seed interpreters have no `cd`, which is why
the exec happens from inside `seed/`. Once stage0 has built the mescc-tools it
execs `seed/after.kaem` (ours), which compiles shpack's `kaem`
([vendor/kaem](vendor/kaem): upstream's plus a `PWD` that tracks `getcwd`, an
`include` builtin and a no-malloc-per-command optimization) and execs it with an
empty environment on `bootstrap/start.kaem`. That driver does `cd ..`,
`ROOT=${PWD}`, sets the defaults, `include`s `shpack.conf`, and runs the fixed
kaem-phase package chain -- one child kaem per `bootstrap/<name-version>/kaem.run`,
one store prefix each, one `PATH` prepend each. Nothing is computed on the host
and no file is generated: the configuration reaches every build and `shpack`
itself as environment variables exported by kaem.

## Recipes

One directory per package name: `packages/<name>/package.star`, with optional
`patches/` and `files/`. A recipe is [Starlark](star/DIALECT.md): directives
declare versions (with source checksums), dependencies, patches and a build
system, and phase functions return the actions that build the package:

```python
"""GNU binary utilities."""

license("GPL-3.0-or-later")
version("2.30", sha256 = "8c38...", url = "https://ftp.gnu.org/gnu/binutils/binutils-2.30.tar.gz")
build_system("autotools")
depends_on("tcc", type = "build")
depends_on("musl")
depends_on("gmake@4.4.1", type = "build")
depends_on("dash@0.5.12", type = "build")
patch("arm64-elfnn-howto.patch", when = "target=aarch64:")

def configure_args(ctx):
    return ["--with-sysroot=" + ctx.dep("musl").prefix, "--disable-nls"]
```

The directives are Spack's, with Spack's signatures; the docstring is the
description, and `homepage`, `parallel = False` and `build_directory` are
globals where a Spack package has class attributes. Dependency types are
Spack's too, `("build", "link")` by default: a build's PATH holds its `build`
dependencies and what they `run`, not the whole closure, and only `link`
dependencies reach the compiler wrapper's `-I`/`-L`/rpath.

`version` is repeatable (the first one declared is the default), and `when=`
ties a dependency, patch, resource or build system to declared versions
(`@=V`, or `@=V1,=V2`), in Spack's spec syntax, so one recipe can carry
several versions with different pinned deps:

```python
version("4.7-2013.11", sha256 = "...", url = "...")
version("8.5.0", sha256 = "...", url = "...")
depends_on("mpfr@2.4.2", when = "@=4.7-2013.11")
when("@=8.5.0", [                   # Spack's `with when("@=8.5.0"):`
    depends_on("mpfr@3.1.6"),
    depends_on("gmake", type = "build"),
])
```

Evaluation is pure. A recipe sees only its own text, the modules it loads
and the build context `ctx`: name, version, arch, prefix, `sh` (the store
shell), `makejobs`, the stage paths, `ctx.dep(name).prefix` and
`ctx.satisfies(when)`. It cannot touch the file system or run anything
itself; it returns actions. [star/PROTOCOL.md](star/PROTOCOL.md) is the full
contract. Because it is a contract rather than the C code, another Starlark
implementation (or a future Spack) can evaluate the same recipes.

## Build systems and phases

Every build runs: `fetch` (sha256-verify distfiles) -> `stage` (unpack to a
scratch dir) -> `patch` -> plan -> the phases -> `finalize` (write the `.spack/`
metadata). The build systems are Starlark modules in `build_systems/`; a
recipe overrides a phase by defining a function of the same name, and can
call the default explicitly (`load("//build_systems/autotools.star",
autotools_install = "install")`):

| build_system | phases | argument hooks |
|---|---|---|
| `generic` | `edit install` (install required) | -- |
| `makefile` | `edit build install` | `build_targets`, `install_targets` |
| `autotools` | `edit configure build install` | `configure_args`, `build_args`, `install_targets` |

A phase returns a list of actions: `run(...)`, `setenv`/`prepend_path`,
`chdir`, `mkdir`, `copy`, `move`, `remove`, `symlink`, `write_file`,
`substitute` (literal), `filter_file` (a regex subset that means the same in
sed and Python), and a few more. `setup_build_environment(ctx)` runs first
and may only set environment variables. When a build step has to inspect
build output, `sh(script)` is the escape hatch; t-lint counts its uses.

`star plan` renders the actions as a plain script (`$VAR/spec/<id>/build.sh`,
kept in the prefix as `.spack/shpack-build.sh`), which the builder sources, so what
ran is always there to read.

## Concretization and store

The concretizer is Starlark too ([shpack/lib/concretize.star](shpack/lib/concretize.star)),
run by `star concretize`: a pure function from the recipes, their file hashes
and the externals to the state files and `dag.mk`, in the spirit of Spack's
old greedy concretizer rather than its solver. `shpack install <name>` resolves names to concrete versions (the first version
a recipe declares wins; `name@version` pins; the externals table is the fallback
for names without a recipe), walks `depends_on` into a
DAG, and assigns every node a Merkle hash: sha256 over the recipe text,
auxiliary files, the build-system modules it loads, the evaluator version,
source checksums, target arch, and the hashes and types of all direct dependencies. Anything changing anywhere in a package's closure changes its
hash.

The store is a Spack install tree. Every package installs where Spack would
put it, `$STORE/linux-<target>/<name>-<version>-<hash>` (the hash in Spack's
spelling: 32 base32 characters, of which `shpack spec` and the logs show the
first 7, as `spack find -l` does), with its metadata in `.spack/` as Spack
keeps it: `spec.json`, `spack-build-out.txt`, the recipe under `repos/`, plus
shpack's hash manifest and rendered plan. After every install, shpack merges
what it installed into `$STORE/.spack-db/index.json` (`lib/spackdb.star`), so
Spack reads the store as is -- no `spack reindex`:

```console
$ spack config add config:install_tree:root:$PWD/store
$ spack find -l
-- linux-shpack-aarch64 / no compilers --------------------------
4cxpi2c gcc@16.1.0  ...
```

With `shpack/` as a Spack repository (`repo.yaml`, and the `star-recipes`
branch of Spack for `package.star`), Spack can also rebuild a node in place
(`spack install --overwrite /4cxpi2c`); shpack then treats the prefix as
installed, and keeps Spack's record. Packages the kaem phase already installed (unhashed
`$STORE/<name>-<version>` prefixes) are registered in `etc/externals`,
Spack-`packages.yaml`-style; they resolve like any other candidate and
contribute their identity to dependents' hashes.

## Scheduling

Concretization emits `dag.mk` (one stamp target per node, direct deps as
prerequisites) and GNU make runs the DAG in parallel. Each build is its own
process with a precomposed PATH: own prefix, then its build dependencies and
what they run (Spack's rule, see [PROTOCOL.md](star/PROTOCOL.md)),
most-derived-first, then `BASEPATH` (the kaem-phase base layer plus stage0 seed
dirs). No runtime PATH composition, exactly one provider per tool. Logs are
per-package; a failure prints the log tail and stops. When the DAG contains
`SHPACK_BOOTSTRAP_MAKE` (gmake@4.4.1), it is built first serially under the
race-prone bootstrap make 3.82, and everything else runs `-j$JOBS` under the new
make's fifo jobserver.

## CLI

```
shpack install <spec>...     concretize + build (spec: name or name@version)
shpack concretize <spec>...  resolve and emit dag.mk only
shpack build-one <id>        build one node (internal, called from dag.mk)
shpack env <name|id>         print a node's composed environment
shpack find                  list concretized/installed packages
shpack spack-db              record the last concretization's installs in .spack-db
```

State lives under `$SHPACK_VAR` (default `$BUILDDIR/shpack`): `spec/<id>/` node dirs,
`topo`, `index`, `dag.mk`, `stamps/`, `logs/`, `stage/`. The store itself is the
only persistent output; `build-one` short-circuits when a node's prefix already
carries `.spack/spec.json`, whoever installed it.

## Sandboxing

Whether or not the tree runs in a changed root is orthogonal to per-build
isolation. Every individual package build is wrapped in a **Landlock sandbox**
that restricts filesystem access to just that build's declared inputs and its
output prefix. That sandbox is a tiny self-contained C program (`sandbox-1.0`)
bootstrapped early in the chain -- right after `tcc`+`musl` -- so it covers the
entire shell phase. There is no `/bin/sh` anywhere: `shpack` and every build
invoke the store `dash` explicitly, so a host shell is never picked up.

This is what makes running directly on the host safe: even with no chroot, a
build cannot read or write outside its declared inputs and output prefix.
`run-rootfs.sh` adds a change of root on top, hiding the host `/usr` entirely,
but the per-build confinement is identical either way.

## Tool budget

shpack core runs under the first bootstrap shell: dash 0.5.12, coreutils 5.0,
sed 4.0.9, make 3.82, and the stage0 `sha256sum`. There is no grep, awk, find,
xargs or mktemp at that point, and `expr`/`cut`/`tac` are avoided to keep the
budget small; `tests/t-lint.sh` enforces this. Configuration is the
environment: the kaem driver exports `ROOT`, `STORE`, `DISTFILES`, `BUILDDIR`,
`ARCH`, `BASEPATH` (its final `PATH`) and optionally `JOBS`; `etc/config` only
derives the rest (`CONFIG_SHELL`, `SANDBOX`, ...) from `$STORE`.

## Tests

`tests/run.sh` runs the suite on the host under dash: resolution and
concretization, Merkle-hash propagation, end-to-end installs of toy packages
(real tarballs, patches, all three build systems, two-stage make bring-up), and
the tool-budget lint. The fixture exports the same variables the kaem driver
would. No chroot required.

[^fast]: 14 minutes 9 seconds on an Intel Core Ultra 9 285 from 2025.
[^bench]: 28-29 minutes on an 8-core AMD Ryzen 7 3700X from 2019.
[^bwrap]: `bwrap` is used for convenience (only by `run-rootfs.sh`); this may be replaced with a simpler `unshare`-based wrapper later.

[1]: https://github.com/FransFaase/MES-replacement
[2]: https://github.com/fosslinux/live-bootstrap
[3]: https://github.com/oriansj/stage0-posix
[4]: https://github.com/spack/spack
[5]: shpack/packages
[6]: https://dl.acm.org/doi/10.1145/358198.358210
[7]: https://docs.kernel.org/userspace-api/landlock.html
