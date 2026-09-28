# The star dialect

star implements [Starlark](https://github.com/bazelbuild/starlark/blob/master/spec.md)
with the restrictions below. The point of pinning them is portability. Any
program star accepts must mean the same thing, value for value, on the other
backends (starlark-go, starlark-rust, a future Python evaluator in Spack), so
the dialect sits inside what all of them do by default. Where a backend differs,
star rejects the construct rather than picking a side.

## Values

| type | notes |
|---|---|
| `NoneType`, `bool` | as specified |
| `int` | **64-bit signed**. Overflow in `+ - * << //` and in literals is an error (`int overflow ... (ints are 64-bit)`), never a silent wrap or a bigint. |
| `string` | **byte strings**, as in starlark-go: `len`, indexing and slicing count bytes. `s.elems()`/`s.elem_ords()` are byte views; `s.codepoints()`/`s.codepoint_ords()` decode UTF-8 (invalid bytes read as U+FFFD). Strings are not iterable. |
| `list`, `tuple`, `dict` | as specified; dicts keep insertion order, which deletion does not disturb |
| `range` | as specified |
| `function`, `builtin_function_or_method` | as specified |
| `struct` | `struct(**kwargs)`, as in starlark-go's `starlarkstruct`: immutable, fields sorted by name in `repr`/`dir` |

**Not supported:** `float` (literals, `/`, `float()`, `%f` and friends), `set`,
`bytes`. They are errors in star.

## Statements

- No `while`.
- No `if`/`for` at the top level of a file (inside functions they are fine;
  comprehensions work anywhere).
- No reassignment of a global, and no rebinding of a name bound by `load`.
- No recursion: calling a function that is already active is an error. This
  is checked at run time, as in starlark-go.
- `load("//path/to/x.star", "name", alias = "name")`: `//` is the root the host
  names; any other path is relative to the loading file and may not contain
  `..`. Names starting with `_` cannot be loaded.

These are starlark-go's defaults (its `-recursion`, `-globalreassign` and
`-toplevelcontrol` options off; `set` off).

## Fixed choices

- **Comparison depth.** `==` and `<` descend at most 10 levels into nested
  containers (starlark-go's `CompareLimit`); deeper comparisons are an error.
- **Case mapping and character classes** (`upper`, `lower`, `title`,
  `capitalize`, `is*`) are ASCII-only. A non-ASCII receiver is an error,
  because Go and Python apply Unicode tables that star does not carry.
- **`hash(s)`** is Java's `String.hashCode` over UTF-16 code units, as in
  starlark-go, and is defined on strings only.
- **`print`** writes to stderr (in recipes) and never affects results.
- **Frozen values.** Every value reachable from a module's globals is frozen
  when the module finishes loading. Mutating it is an error.

## Conformance

`star/tests/run.sh` runs starlark-go's own test files through a harness
equivalent to its `eval_test.go`. The lines that exercise the excluded
features are listed, with reasons, in `tests/starlark-go/exclusions`.
`tests/dialect.star` checks the restrictions themselves.
