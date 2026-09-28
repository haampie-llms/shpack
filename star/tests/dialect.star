# Tests of star's dialect restrictions (star/DIALECT.md): what the pinned
# dialect rejects, and the choices it fixes, so that star-valid programs mean
# the same on every conforming backend.

load("assert.star", "assert")

# int is 64-bit: overflow is an error, not a bigint
assert.eq(9223372036854775807 + 0, 9223372036854775807)
assert.fails(lambda: 9223372036854775807 + 1, "int overflow")
assert.fails(lambda: -9223372036854775807 - 2, "int overflow")
assert.fails(lambda: 4611686018427387904 * 2, "int overflow")
assert.fails(lambda: 1 << 63, "int overflow")
assert.eq(-9223372036854775807 - 1, -(1 << 62) * 2)
assert.fails(lambda: 7 / 2, "floating-point division is not supported")
assert.eq(7 // 2, 3)
assert.eq(-7 // 2, -4)
assert.eq(-7 % 2, 1)
assert.fails(lambda: float(1), "not supported")
assert.fails(lambda: int("9223372036854775808"), "out of range")

# strings are byte strings and not iterable
assert.eq(len("é"), 2)
assert.eq(len("é"[0]), 1)
assert.fails(lambda: [c for c in "abc"], "not iterable")
assert.eq(list("abc".elems()), ["a", "b", "c"])

# case mapping and classes are ASCII-only; non-ASCII is an error, not a guess
assert.eq("abc".upper(), "ABC")
assert.fails(lambda: "é".upper(), "non-ASCII")
assert.fails(lambda: "é".isalpha(), "non-ASCII")

# structs: fields sorted, immutable
s = struct(b = 1, a = 2)
assert.eq(str(s), "struct(a = 2, b = 1)")
assert.eq(dir(s), ["a", "b"])

# dicts keep insertion order
d = {"z": 1, "a": 2, "m": 3}
assert.eq(list(d), ["z", "a", "m"])
d.pop("a")
d["a"] = 4
assert.eq(list(d), ["z", "m", "a"])

# values are frozen once the module has loaded
frozen = [1]
def later():
    frozen.append(2)
---
# no recursion
def f(n):
    return f(n - 1) if n else 0 ### "called recursively"
f(3)
---
# no while loops
def g():
    while True: ### "does not support while loops"
        pass
---
# no top-level control flow
if True: ### "if statement not within a function"
    pass
---
# no global reassignment
x = 1
x = 2 ### "cannot reassign global x"
---
# no floats
x = 1.5 ### "floating-point numbers are not supported"
---
# no bytes
x = b"abc" ### "bytes literals are not supported"
---
load("assert.star", "assert")

# comparison depth is limited as in starlark-go
deep = []
for_nesting = [deep]
def nest(x, n):
    for _ in range(n):
        x = [x]
    return x
assert.fails(lambda: nest(1, 12) == nest(1, 12), "maximum recursion")
assert.eq(nest(1, 5), nest(1, 5))
