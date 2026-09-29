/* SPDX-License-Identifier: MIT
 *
 * star -- unity build. The kaem chain has no globs and no make, so the whole
 * interpreter is one translation unit:
 *
 *     tcc -static -o star star/star.c
 *     cc -O2 -o star star/star.c
 */
#include "src/util.c"
#include "src/value.c"
#include "src/lex.c"
#include "src/parse.c"
#include "src/resolve.c"
#include "src/eval.c"
#include "src/builtins.c"
#include "src/strmethods.c"
#include "src/regex.c"
#include "src/host.c"
#include "src/sha256.c"
#include "src/sha1.c"
#include "src/concretize.c"
#include "src/main.c"
