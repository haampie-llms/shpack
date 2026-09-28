# SPDX-License-Identifier: MIT
# Run by kaem.run right after star is built: a fail() here aborts the chain.

def check(got, want):
    if got != want:
        fail("smoke: got %r, want %r" % (got, want))

def fib():
    a, b, out = 0, 1, []
    for _ in range(10):
        out.append(a)
        a, b = b, a + b
    return out

check(fib(), [0, 1, 1, 2, 3, 5, 8, 13, 21, 34])
check({k: len(k) for k in ["ab", "c"]}, {"ab": 2, "c": 1})
check("x={x} y={}".format(1, x = "a"), "x=a y=1")
check("%s-%d" % ("v", 42), "v-42")
check(sorted(["b", "a", "c"], reverse = True), ["c", "b", "a"])
check(" a  b ".split(), ["a", "b"])
check(struct(b = 1, a = 2).a, 2)
check(-7 // 2, -4)
check((1 << 62) + ((1 << 62) - 1), 9223372036854775807)
print("star smoke test: ok")
