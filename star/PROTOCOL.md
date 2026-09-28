# The recipe protocol

This is the contract between a package recipe (`package.star`), the evaluator
that runs it, and the host that builds from the result. star is one
evaluator; any other Starlark implementation of the [dialect](DIALECT.md) can
take its place if it produces the same two records described below. The C
code is not the interface.

A backend has two jobs:

1. `recipe(root, repo, name)`: load `repo/name/package.star` and return its
   **directive record**.
2. `plan(root, repo, name, ctx)`: evaluate the recipe's phases against a
   **build context** and return the **action list** of each phase.

Evaluation is pure. A recipe sees only its own text, the modules it loads,
and the `ctx` value. Anything that depends on the machine or on build output
happens later, when the host executes the actions.

## Recipes

A recipe is a Starlark module. The host predeclares the directives and the
action constructors below; `load()` paths starting with `//` resolve against
`root`, the directory that holds `build_systems/`. The directives are a subset
of Spack's, with Spack's signatures, and what Spack keeps in class attributes
a recipe keeps in globals and its docstring:

```python
"""GNU make: the parallel-safe make of the bootstrap."""

homepage = "https://www.gnu.org/software/make/"
license("GPL-3.0-or-later")

version("4.4.1", sha256 = "dd16...", url = "https://.../make-4.4.1.tar.gz")
build_system("autotools")
depends_on("tcc", type = "build")
depends_on("musl@1.1.24")
parallel = False
```

### Directives (callable only while the recipe loads)

| directive | meaning |
|---|---|
| `version(ver, sha256=, url=, fname=)` | a buildable version and its source. The first declared version is the default for a bare name. `fname` defaults to the URL's basename. A version without `sha256` has no source. |
| `resource(url=, sha256=, fname=, when=)` | an extra distfile, unpacked into the stage beside the main source |
| `depends_on(spec, when=, type=)` | one dependency, `name` or `name@version` (exact). `type` is Spack's: `"build"`, `"link"`, `"run"`, `"test"` or a tuple of them; the default is `("build", "link")`. |
| `patch(file, level=1, when=)` | apply `patches/<file>` with `-p<level>` |
| `license(id, checked_by=, when=)` | an SPDX license identifier (`checked_by` is not kept) |
| `when(cond, [...])` | Spack's `with when(cond):`. The list holds what `depends_on`, `patch`, `resource` and `license` return (or nested `when` calls); each of those directives' conditions becomes its own AND `cond`. Version lists intersect, and an empty intersection is an error. The result is written back as `@=V1,=V2 target=FAMILY:`. Returns the directives, so `when` nests. |
| `build_system(*values, default=)` | `generic`, `makefile` or `autotools`, at most once. A value is a name or `conditional(name, ..., when=)`. A node builds with `default` (the first value unless given) if its condition holds, else with the first value whose condition does. Without the directive: `generic`. |

Starlark has no `with` statement, hence `when()` as a call. The directives in
its list run first, as arguments do, and `when` then narrows them:

```python
when("@=4.9-musl", [
    depends_on("gcc-boot0", type = "build"),
    depends_on("xz@5.2.5-musl", type = "build"),
    when("target=aarch64:", [patch("arm64.patch")]),
])
when("@=4.9", [depends_on(t, type = "build") for t in ["gmake", "xz"]])
```

`when=` takes a subset of Spack's spec syntax, space separated: `@=VERSION`
(exactly this version of the package), `@=V1,=V2,...` (any of these), and
`target=x86_64:` / `target=aarch64:` (the target family; `patch()` only).
Anything else is an error.

### Attributes

| global | meaning |
|---|---|
| docstring | the description: the module's first statement, if it is a string; whitespace runs become single spaces |
| `homepage` | a string |
| `parallel` | `False`: build with `-j1` |
| `build_directory` | configure/build out of tree, in this relative subdirectory of the source |

### Phases

The build system (a module `//build_systems/<name>.star`) exports `phases`, a
list of phase names, and a default function for each. A recipe overrides a
phase by defining a function with the same name. Each phase is a function
`f(ctx)` returning a list of actions. The host evaluates them in order:

- `setup_build_environment(ctx)` first, if defined. It may return only
  `setenv`, `prepend_path` and `unsetenv`.
- then every phase in `phases`.

A recipe calls a default explicitly, e.g.
`load("//build_systems/autotools.star", autotools_install = "install")` and
`return autotools_install(ctx) + [...]`. Build systems reach the recipe's
argument hooks (`configure_args(ctx)`, `build_args`, `build_targets`,
`install_targets`, all returning lists of strings) through `ctx.pkg`.

### The build context

`ctx` is a frozen struct:

| field | |
|---|---|
| `name`, `version`, `id` | the node; `id` is `name-version` |
| `arch` | `amd64` or `aarch64` |
| `prefix` | the install prefix |
| `sh` | the build shell (the recipe's `dash` dependency) |
| `stage_dir`, `source_dir` | where sources are unpacked; the first directory there |
| `package_dir`, `package_files` | the recipe's directory and the files in it (relative) |
| `jobs`, `makejobs` | the job count; `[]`, or `["-j1"]` for `parallel = False` |
| `file_prefix_map`, `debug_prefix_map` | `-ffile-prefix-map=<stage>=.`, `-fdebug-prefix-map=<stage>=.` |
| `build_directory` | the directive's value, or `None` |
| `pkg` | a struct of the recipe's exported globals |
| `dep(name)` | `.prefix` of `name` among the direct dependencies, then the closure (any type) |
| `satisfies(when)` | the `when=` grammar, against this node |

The shpack builder writes it as a Starlark file, `ctx = {...}`, with the
fields above minus the computed ones (`build_directory`, `pkg`, `dep`,
`satisfies`), plus `deps`, a dict from dependency name to prefix.

## Actions

Actions are structs of type `action` with an `op` field. Paths are relative
to the current directory unless absolute. Where noted, a path may be a glob
(`*`, `?`, `[...]`); `DIR/**/PATTERN` matches files at any depth. A glob must
match something.

| constructor | effect |
|---|---|
| `run(*argv, cwd=, env=, stdout=)` | run a program; list arguments are flattened one level |
| `sh(script, cwd=)` | escape hatch: a POSIX sh script under the build shell with `-e`. For build steps that must inspect build output. |
| `setenv(name, value)`, `prepend_path(name, value)`, `unsetenv(name)` | environment for the rest of the build |
| `chdir(path)` | current directory for the rest of the build (glob allowed, matching one) |
| `mkdir(path, ...)` | with parents |
| `copy(src, dst, recursive=, preserve=, force=)` | `src` may be several paths or globs; `preserve` keeps modes, times and links |
| `move(src, dst)` | |
| `remove(paths, recursive=)` | missing paths are fine |
| `symlink(target, link, force=, if_missing=)`, `hardlink(...)` | |
| `symlink_each(targets, dir, prefix=, relative=, if_missing=, exclude=)` | a link `dir/<prefix><basename>` for each existing target (paths or globs, expanded once); `relative` links to the base name; `exclude` is a base-name glob |
| `chmod(mode, paths)` | mode as octal digits, e.g. `"755"` |
| `write_file(path, content, mode=)`, `append_file(path, content)` | exact bytes |
| `substitute(files, old, new)` | replace every occurrence of the literal `old`, line by line |
| `filter_file(files, regex, repl)` | replace every match of `regex` (the portable subset: literals, `.`, `*` after an atom, `^` first, `$` last, `[...]`, backslash-escaped metacharacters; `+ ? ( ) { } \|` must be escaped) with the literal `repl`, line by line |

## Hosts

A host executes plans. Two hosts give byte-identical installs of the same
recipe (up to the store paths in them) when they agree on the following. This
is what shpack's builder does, and what Spack's adapter (`spack.star_package`)
reproduces:

- **Resolution.** `name@version` pins that exact version. A bare name means
  the first version its recipe declares; a recipe always beats an external of
  the same name. A package never depends on another version of itself, so
  bootstrap stages get names of their own (`gcc-boot0`, `gcc-boot1`, ...).
- **Staging.** The main archive, then the resources in declaration order,
  are unpacked side by side into the stage directory with the compressor and
  `tar` on the build PATH. `source_dir` is the first directory in the stage,
  in sorted order. The recipe's patches are then applied in order with
  `patch -p<level>` from the build PATH, and `#!` interpreters in the whole
  stage are rewritten to `ctx.sh`.
- **Environment.** Nothing is inherited from the invoking process:
  - `PATH` is the prefix's own `bin`, then the `bin` of the dependencies
    that Spack makes runnable in a build (`effective_deptypes`), then the
    host's base PATH. Those are the direct `build` (or `test`) dependencies,
    and what each of them runs: its `run` dependencies, found through `run`
    and `link` edges. They are not the node's own `run`-only dependencies,
    its `link`-only ones, or the build dependencies of its dependencies. They
    appear in the reverse of a DFS post-order over the declared dependencies
    (all types).
  - `SOURCE_DATE_EPOCH=0`; `SHELL`, `sh` and `MAKEFLAGS` carry `ctx.sh`;
    `HOME` and `TMPDIR` are build scratch.
  - Also set: `PREFIX`, `ARCH`, `JOBS`, `makejobs`, and, from the direct
    `link` dependencies, the compiler-wrapper variables and
    `PKG_CONFIG_PATH`.
- **Finalization.** `lib/*.la` and `lib64/*.la` are removed. Modes are
  normalized: directories 755, files 644, or 755 if any execute bit is set.
- **Order.** `ctx.deps` is the direct dependencies, then the closure sorted
  by `name-version`, first match winning.
- **Build order.** Every dependency, whatever its type, is installed before
  its dependents.

## Canonical forms

`star recipe --format json` and `star plan --format json` print the two
records as JSON. Keys appear in a fixed order: directives in declaration
order, action fields sorted by name. Two backends agree when their JSON is
byte-identical over a set of recipes. That is the test for swapping one in.

The shpack host consumes other renderings of the same records.
`--format shpack` writes the directive record as the state files under
`$VAR/recipe/<name>/`. `--format sh` renders the plan as a POSIX sh script
that uses two helpers the builder defines, `star_sed` and `star_rglob`.
