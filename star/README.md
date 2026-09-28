# star

A Starlark interpreter in C, small enough to be built early in a bootstrap
chain. shpack builds it with its seed-grown tcc 0.9.27 and musl, right after
the compiler exists, and evaluates every package recipe with it.

- `src/`: lexer, parser, resolver, tree-walking evaluator, builtins, and
  `host.c`, the shpack host API (directives, build context, actions,
  renderers). It is written in C99 that tcc accepts and builds with any cc.
- `star.c`: the unity build, so the build is one command:

      tcc -static -o star star.c        # as in the bootstrap
      cc -O2 -o star star.c             # anywhere else

- [DIALECT.md](DIALECT.md): the Starlark dialect star implements (64-bit
  ints, byte strings, no floats, sets, while or recursion) and why it is
  pinned.
- [PROTOCOL.md](PROTOCOL.md): the recipe protocol, which is the contract any
  other backend has to meet to replace star.
- `src/concretize.c`: the host of shpack's concretizer, which is Starlark
  (`shpack/lib/concretize.star`): the recipes, file hashes (`src/sha256.c`)
  and externals go in, the state files come out.
- `tests/run.sh`: starlark-go's conformance tests (vendored, BSD-3) plus
  star's own dialect tests.

## Usage

    star run FILE.star
    star test [--xfail LIST] FILE.star...
    star recipe --repo DIR --root DIR [--format shpack|json] [--out DIR] NAME
    star plan   --repo DIR --root DIR --ctx CTX.star [--format sh|json] NAME
    star concretize --repo DIR --root DIR --module FILE --cfg CFG.star --out DIR SPEC...

Memory comes from an arena that is never freed, because one process
evaluates one thing and exits. An error unwinds with a traceback
(outermost frame first) and exit status 1.
