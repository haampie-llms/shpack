/* SPDX-License-Identifier: MIT
 * util.c -- arena, buffers, interning, errors, checked int64 arithmetic. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "star.h"

/* ---------------------------------------------------------------- arena -- */

static char *arena_p;
static size_t arena_left;

void *arena_alloc(size_t n)
{
    void *p;
    n = (n + 15) & ~(size_t)15;
    if (n > arena_left) {
        size_t chunk = n > (1u << 20) ? n : (1u << 20);
        arena_p = calloc(1, chunk);
        if (!arena_p)
            fatal("out of memory");
        arena_left = chunk;
    }
    p = arena_p;
    arena_p += n;
    arena_left -= n;
    return p;
}

char *arena_strndup(const char *s, size_t n)
{
    char *p = arena_alloc(n + 1);
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}

char *arena_strdup(const char *s)
{
    return arena_strndup(s, strlen(s));
}

void *arena_grow(void *old, size_t oldn, size_t newn)
{
    void *p = arena_alloc(newn);
    if (old && oldn)
        memcpy(p, old, oldn < newn ? oldn : newn);
    return p;
}

/* ------------------------------------------------------------------ Buf -- */

void buf_init(Buf *b)
{
    b->p = NULL;
    b->len = b->cap = 0;
}

static void buf_reserve(Buf *b, size_t n)
{
    size_t cap;
    if (b->len + n + 1 <= b->cap)
        return;
    cap = b->cap ? b->cap * 2 : 64;
    while (cap < b->len + n + 1)
        cap *= 2;
    b->p = arena_grow(b->p, b->len, cap);
    b->cap = cap;
}

void buf_putc(Buf *b, int c)
{
    buf_reserve(b, 1);
    b->p[b->len++] = (char)c;
}

void buf_put(Buf *b, const char *s, size_t n)
{
    buf_reserve(b, n);
    memcpy(b->p + b->len, s, n);
    b->len += n;
}

void buf_puts(Buf *b, const char *s)
{
    buf_put(b, s, strlen(s));
}

void buf_printf(Buf *b, const char *fmt, ...)
{
    va_list ap;
    char small[256];
    int n;
    va_start(ap, fmt);
    n = vsnprintf(small, sizeof small, fmt, ap);
    va_end(ap);
    if (n < (int)sizeof small) {
        buf_put(b, small, n);
        return;
    }
    buf_reserve(b, n);
    va_start(ap, fmt);
    vsnprintf(b->p + b->len, n + 1, fmt, ap);
    va_end(ap);
    b->len += n;
}

char *buf_cstr(Buf *b)
{
    buf_reserve(b, 0);
    b->p[b->len] = 0;
    return b->p;
}

/* ------------------------------------------------------------ interning -- */

static Str **itab;
static int icap, icount;

static uint32_t fnv(const char *s, int n)
{
    uint32_t h = 2166136261u;
    int i;
    for (i = 0; i < n; i++) {
        h ^= (unsigned char)s[i];
        h *= 16777619u;
    }
    return h;
}

Str *intern_n(const char *s, int n)
{
    uint32_t h = fnv(s, n);
    int i;
    Str *x;
    if (icount * 2 >= icap) {
        Str **old = itab;
        int oldcap = icap, j;
        icap = icap ? icap * 2 : 1024;
        itab = arena_alloc(sizeof(Str *) * icap);
        icount = 0;
        for (j = 0; j < oldcap; j++) {
            if (old[j]) {
                uint32_t hh = old[j]->hash;
                int k = hh & (icap - 1);
                while (itab[k])
                    k = (k + 1) & (icap - 1);
                itab[k] = old[j];
                icount++;
            }
        }
    }
    i = h & (icap - 1);
    while (itab[i]) {
        x = itab[i];
        if (x->hash == h && x->len == n && memcmp(x->s, s, n) == 0)
            return x;
        i = (i + 1) & (icap - 1);
    }
    x = (Str *)mk_str(s, n);
    x->hash = h;
    itab[i] = x;
    icount++;
    return x;
}

Str *intern(const char *s)
{
    return intern_n(s, strlen(s));
}

int str_eq(Str *a, const char *s)
{
    int n = strlen(s);
    return a->len == n && memcmp(a->s, s, n) == 0;
}

/* --------------------------------------------------------------- errors -- */

Catch *catch_top;
Frame *cur_frame;
int call_depth;
char *err_msg;
char *err_trace;
Pos err_pos;
Pos err_stack[64];      /* innermost first */
int err_nstack;

void fatal(const char *fmt, ...)
{
    va_list ap;
    fputs("star: internal error: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(2);
}

/* Record the traceback (outermost first, like starlark-go's CallStack) and
 * unwind to the innermost catch point. */
void star_verror(const char *fmt, va_list ap)
{
    Buf b, t;
    Frame *f;
    Frame *stack[64];
    int n = 0, i;
    buf_init(&b);
    {
        char small[512];
        va_list ap2;
        int len;
        va_copy(ap2, ap);
        len = vsnprintf(small, sizeof small, fmt, ap2);
        va_end(ap2);
        if (len < (int)sizeof small)
            buf_put(&b, small, len);
        else {
            char *big = arena_alloc(len + 1);
            vsnprintf(big, len + 1, fmt, ap);
            buf_put(&b, big, len);
        }
    }
    err_msg = buf_cstr(&b);

    buf_init(&t);
    for (f = cur_frame; f && n < 64; f = f->parent)
        stack[n++] = f;
    err_pos.file = NULL;
    err_pos.line = err_pos.col = 0;
    err_nstack = 0;
    for (i = 0; i < n; i++)
        if (stack[i]->info && err_nstack < 64) {
            err_stack[err_nstack].file = stack[i]->info->filename;
            err_stack[err_nstack].line = stack[i]->line;
            err_stack[err_nstack].col = stack[i]->col;
            err_nstack++;
        }
    buf_puts(&t, "Traceback (most recent call last):\n");
    for (i = n - 1; i >= 0; i--) {
        f = stack[i];
        if (f->builtin) {
            buf_printf(&t, "  <builtin>: in %s\n", f->builtin);
            continue;
        }
        buf_printf(&t, "  %s:%d:%d: in %s\n",
                   f->info ? f->info->filename : "?", f->line, f->col,
                   f->info ? f->info->name->s : "?");
        if (!err_pos.file && f->info) {
            err_pos.file = f->info->filename;
            err_pos.line = f->line;
            err_pos.col = f->col;
        }
    }
    buf_printf(&t, "Error: %s\n", err_msg);
    err_trace = buf_cstr(&t);

    if (!catch_top) {
        fputs(err_trace, stderr);
        exit(1);
    }
    longjmp(catch_top->jb, 1);
}

void star_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    star_verror(fmt, ap);
    va_end(ap);
}

/* ------------------------------------------------------ int64 checking -- */

int64_t add64(int64_t a, int64_t b)
{
    if ((b > 0 && a > INT64_MAX - b) || (b < 0 && a < INT64_MIN - b))
        star_error("int overflow in %lld + %lld (ints are 64-bit)", (long long)a, (long long)b);
    return a + b;
}

int64_t sub64(int64_t a, int64_t b)
{
    if ((b < 0 && a > INT64_MAX + b) || (b > 0 && a < INT64_MIN + b))
        star_error("int overflow in %lld - %lld (ints are 64-bit)", (long long)a, (long long)b);
    return a - b;
}

int64_t mul64(int64_t a, int64_t b)
{
    if (a == 0 || b == 0)
        return 0;
    if ((a == -1 && b == INT64_MIN) || (b == -1 && a == INT64_MIN))
        goto overflow;
    if (a > 0) {
        if (b > 0 ? a > INT64_MAX / b : b < INT64_MIN / a)
            goto overflow;
    } else {
        if (b > 0 ? a < INT64_MIN / b : a < INT64_MAX / b)
            goto overflow;
    }
    return a * b;
overflow:
    star_error("int overflow in %lld * %lld (ints are 64-bit)", (long long)a, (long long)b);
    return 0;
}
