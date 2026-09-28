/* SPDX-License-Identifier: MIT
 * eval.c -- the tree-walking evaluator: calls and argument binding,
 * expressions, statements, assignment, comprehensions, and modules. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "star.h"

Options opts;
Dict *predeclared;
char *(*module_path_hook)(const char *name, const char *from_file);

#define MAX_DEPTH 400

enum { CF_NORMAL, CF_BREAK, CF_CONTINUE, CF_RETURN };

static V eval(Frame *fr, Node *e);
static int exec_stmts(Frame *fr, Node **s, int n, V *ret);

/* ---------------------------------------------------------------- calls -- */

static const char *plural(int n) { return n == 1 ? "" : "s"; }

static V call_function(Function *fn, Args *a)
{
    FuncInfo *fi = fn->info;
    Frame fr;
    V *locals;
    V kwargs = NULL;
    int i, npos = fi->npositional, nnamed = fi->npositional + fi->nkwonly;
    V ret = None;

    if (fi->recursing && !opts.recursion)
        star_error("function %s called recursively", fi->name->s);
    if (call_depth >= MAX_DEPTH)
        star_error("Starlark stack overflow");

    locals = arena_alloc(sizeof(V) * (fi->nlocals + 1));

    /* positional arguments */
    if (a->npos > npos) {
        if (!fi->has_varargs) {
            if (npos == 0)
                star_error("function %s accepts no positional arguments (%d given)", fi->name->s, a->npos);
            star_error("function %s accepts at most %d positional argument%s (%d given)",
                       fi->name->s, npos, plural(npos), a->npos);
        }
    }
    for (i = 0; i < a->npos && i < npos; i++)
        locals[i] = a->pos[i];
    if (fi->has_varargs) {
        int nv = a->npos > npos ? a->npos - npos : 0;
        V t = mk_tuple(nv);
        for (i = 0; i < nv; i++)
            AS_TUPLE(t)->items[i] = a->pos[npos + i];
        locals[nnamed] = t;
    }
    if (fi->has_kwargs) {
        kwargs = mk_dict();
        locals[nnamed + fi->has_varargs] = kwargs;
    }
    /* keyword arguments */
    for (i = 0; i < a->nkw; i++) {
        Str *k = a->kwnames[i];
        int j;
        for (j = 0; j < nnamed; j++)
            if (fi->params[j]->s == k)
                break;
        if (j < nnamed) {
            if (locals[j])
                star_error("function %s got multiple values for parameter \"%s\"", fi->name->s, k->s);
            locals[j] = a->kwvals[i];
            continue;
        }
        if (!kwargs)
            star_error("function %s got an unexpected keyword argument \"%s\"", fi->name->s, k->s);
        if (dict_get(kwargs, (V)k))
            star_error("function %s got multiple values for parameter \"%s\"", fi->name->s, k->s);
        dict_set(kwargs, (V)k, a->kwvals[i]);
    }
    /* defaults, and missing arguments */
    {
        int nmissing = 0;
        Buf missing;
        buf_init(&missing);
        for (i = 0; i < nnamed; i++) {
            if (locals[i])
                continue;
            if (fn->defaults && fn->defaults[i]) {
                locals[i] = fn->defaults[i];
                continue;
            }
            if (nmissing++)
                buf_puts(&missing, ", ");
            buf_puts(&missing, fi->params[i]->s->s);
        }
        if (nmissing)
            star_error("function %s missing %d argument%s (%s)", fi->name->s, nmissing,
                       plural(nmissing), buf_cstr(&missing));
    }
    /* cells for captured locals */
    for (i = 0; i < fi->nlocals; i++) {
        if (fi->iscell[i]) {
            Cell *c = arena_alloc(sizeof(Cell));
            c->type = T_CELL;
            c->v = locals[i];
            locals[i] = (V)c;
        }
    }

    memset(&fr, 0, sizeof fr);
    fr.parent = cur_frame;
    fr.info = fi;
    fr.fn = fn;
    fr.module = fn->module;
    fr.locals = locals;
    fr.free = fn->free;
    fr.line = fi->line;
    fr.col = fi->col;
    cur_frame = &fr;
    call_depth++;
    fi->recursing++;
    if (fi->expr) {
        fr.line = fi->expr->line;
        fr.col = fi->expr->col;
        ret = eval(&fr, fi->expr);
    } else if (exec_stmts(&fr, fi->body, fi->nbody, &ret) != CF_RETURN) {
        ret = None;
    }
    fi->recursing--;
    call_depth--;
    cur_frame = fr.parent;
    return ret;
}

V call_value(V fn, Args *a)
{
    switch (TYPE(fn)) {
    case T_FUNCTION:
        return call_function((Function *)fn, a);
    case T_BUILTIN: {
        Builtin *b = (Builtin *)fn;
        Frame fr;
        V r;
        memset(&fr, 0, sizeof fr);
        fr.parent = cur_frame;
        fr.builtin = b->name;
        if (call_depth >= MAX_DEPTH)
            star_error("Starlark stack overflow");
        cur_frame = &fr;
        call_depth++;
        a->self = b->recv;
        a->name = b->name;
        a->builtin = b;
        r = b->fn(a);
        call_depth--;
        cur_frame = fr.parent;
        return r ? r : None;
    }
    }
    star_error("invalid call of non-function (%s)", type_name(fn));
    return NULL;
}

V call_simple(V fn, int n, V *argv)
{
    Args a;
    memset(&a, 0, sizeof a);
    a.npos = n;
    a.pos = argv;
    return call_value(fn, &a);
}

/* --------------------------------------------------------- arg unpacking -- */

void no_kwargs(Args *a)
{
    if (a->nkw)
        star_error("%s: unexpected keyword arguments", a->name);
}

void unpack_positional(Args *a, int min, int max, ...)
{
    va_list ap;
    int i;
    no_kwargs(a);
    if (a->npos < min) {
        if (min == max)
            star_error("%s: got %d arguments, want %d", a->name, a->npos, min);
        star_error("%s: got %d arguments, want at least %d", a->name, a->npos, min);
    }
    if (a->npos > max) {
        if (min == max)
            star_error("%s: got %d arguments, want %d", a->name, a->npos, max);
        star_error("%s: got %d arguments, want at most %d", a->name, a->npos, max);
    }
    va_start(ap, max);
    for (i = 0; i < max; i++) {
        V *out = va_arg(ap, V *);
        *out = i < a->npos ? a->pos[i] : NULL;
    }
    va_end(ap);
}

void unpack_args(Args *a, ...)
{
    va_list ap;
    const char *names[16];
    V *outs[16];
    int n = 0, i, j, optional_from = -1;
    va_start(ap, a);
    for (;;) {
        const char *nm = va_arg(ap, const char *);
        if (!nm)
            break;
        names[n] = nm;
        outs[n] = va_arg(ap, V *);
        *outs[n] = NULL;
        if (nm[strlen(nm) - 1] == '?' && optional_from < 0)
            optional_from = n;
        n++;
    }
    va_end(ap);
    if (optional_from < 0)
        optional_from = n;
    if (a->npos > n)
        star_error("%s: got %d arguments, want at most %d", a->name, a->npos, n);
    for (i = 0; i < a->npos; i++)
        *outs[i] = a->pos[i];
    for (i = 0; i < a->nkw; i++) {
        Str *k = a->kwnames[i];
        for (j = 0; j < n; j++) {
            int len = strlen(names[j]);
            if (names[j][len - 1] == '?')
                len--;
            if (k->len == len && memcmp(k->s, names[j], len) == 0)
                break;
        }
        if (j == n) {
            V cands = mk_list(n);
            const char *sug;
            for (j = 0; j < n; j++) {
                int len = strlen(names[j]);
                list_append(cands, mk_str(names[j], names[j][len - 1] == '?' ? len - 1 : len));
            }
            sug = did_you_mean(k->s, cands);
            if (sug)
                star_error("%s: unexpected keyword argument %s (did you mean %s?)", a->name, k->s, sug);
            star_error("%s: unexpected keyword argument %s", a->name, k->s);
        }
        if (*outs[j])
            star_error("%s: got multiple values for keyword argument %s", a->name, k->s);
        *outs[j] = a->kwvals[i];
    }
    for (i = 0; i < optional_from; i++) {
        if (!*outs[i])
            star_error("%s: missing argument for %s", a->name, names[i]);
    }
}

int64_t want_int(V v, const char *what)
{
    if (TYPE(v) != T_INT)
        star_error("%s: got %s, want int", what, type_name(v));
    return AS_INT(v);
}

Str *want_str(V v, const char *what)
{
    if (TYPE(v) != T_STRING)
        star_error("%s: got %s, want string", what, type_name(v));
    return AS_STR(v);
}

/* -------------------------------------------------------------- binary -- */

static V repeat(V seq, int64_t n)
{
    int len = seq_len(seq), i, j;
    int64_t total;
    if (n <= 0)
        n = 0;
    if (n >= ((int64_t)1 << 31))
        star_error("repeat count %lld too large", (long long)n);
    total = (int64_t)len * n;
    if (total >= ((int64_t)1 << 30))
        star_error("excessive repeat (%d * %lld elements)", len, (long long)n);
    switch (TYPE(seq)) {
    case T_STRING: {
        V s = mk_str("", 0);
        Str *r = arena_alloc(sizeof(Str) + total);
        (void)s;
        r->type = T_STRING;
        r->len = (int)total;
        for (i = 0; i < n; i++)
            memcpy(r->s + (int64_t)i * len, AS_STR(seq)->s, len);
        r->s[total] = 0;
        return (V)r;
    }
    case T_LIST: {
        V l = mk_list((int)total);
        for (i = 0; i < n; i++)
            for (j = 0; j < len; j++)
                list_append(l, AS_LIST(seq)->items[j]);
        return l;
    }
    case T_TUPLE: {
        V t = mk_tuple((int)total);
        for (i = 0; i < n; i++)
            for (j = 0; j < len; j++)
                AS_TUPLE(t)->items[i * len + j] = AS_TUPLE(seq)->items[j];
        return t;
    }
    }
    return NULL;
}

int value_in(V needle, V hay)
{
    int i;
    switch (TYPE(hay)) {
    case T_STRING: {
        Str *h = AS_STR(hay), *nd;
        if (TYPE(needle) != T_STRING)
            star_error("'in <string>' requires string as left operand, not %s", type_name(needle));
        nd = AS_STR(needle);
        if (nd->len == 0)
            return 1;
        for (i = 0; i + nd->len <= h->len; i++)
            if (memcmp(h->s + i, nd->s, nd->len) == 0)
                return 1;
        return 0;
    }
    case T_LIST:
        for (i = 0; i < AS_LIST(hay)->len; i++)
            if (equal(needle, AS_LIST(hay)->items[i]))
                return 1;
        return 0;
    case T_TUPLE:
        for (i = 0; i < AS_TUPLE(hay)->len; i++)
            if (equal(needle, AS_TUPLE(hay)->items[i]))
                return 1;
        return 0;
    case T_DICT:
        /* an unhashable key is simply not in the dict, as in starlark-go */
        return hashable(needle) && dict_get(hay, needle) != NULL;
    case T_RANGE: {
        Range *r = (Range *)hay;
        int64_t x;
        if (TYPE(needle) != T_INT)
            star_error("'in <range>' requires integer as left operand, not %s", type_name(needle));
        x = AS_INT(needle);
        if (r->step > 0) {
            if (x < r->start || x >= r->stop)
                return 0;
            return (x - r->start) % r->step == 0;
        }
        if (x > r->start || x <= r->stop)
            return 0;
        return (r->start - x) % (-r->step) == 0;
    }
    }
    star_error("unknown binary op: %s in %s", type_name(needle), type_name(hay));
    return 0;
}

static int64_t floordiv(int64_t x, int64_t y)
{
    int64_t q;
    if (y == 0)
        star_error("floored division by zero");
    if (x == INT64_MIN && y == -1)
        star_error("int overflow in %lld // %lld (ints are 64-bit)", (long long)x, (long long)y);
    q = x / y;
    if ((x % y != 0) && ((x < 0) != (y < 0)))
        q--;
    return q;
}

static int64_t floormod(int64_t x, int64_t y)
{
    int64_t r;
    if (y == 0)
        star_error("integer modulo by zero");
    if (y == -1)
        return 0;
    r = x % y;
    if (r != 0 && ((r < 0) != (y < 0)))
        r += y;
    return r;
}

V binary_op(int op, V a, V b)
{
    int ta = TYPE(a), tb = TYPE(b);
    switch (op) {
    case T_PLUS:
        if (ta == T_INT && tb == T_INT)
            return mk_int(add64(AS_INT(a), AS_INT(b)));
        if (ta == T_STRING && tb == T_STRING) {
            Str *x = AS_STR(a), *y = AS_STR(b);
            Str *r;
            if (x->len == 0)
                return b;
            if (y->len == 0)
                return a;
            r = arena_alloc(sizeof(Str) + x->len + y->len);
            r->type = T_STRING;
            r->len = x->len + y->len;
            memcpy(r->s, x->s, x->len);
            memcpy(r->s + x->len, y->s, y->len);
            r->s[r->len] = 0;
            return (V)r;
        }
        if (ta == T_LIST && tb == T_LIST) {
            V l = mk_list(AS_LIST(a)->len + AS_LIST(b)->len);
            memcpy(AS_LIST(l)->items, AS_LIST(a)->items, sizeof(V) * AS_LIST(a)->len);
            memcpy(AS_LIST(l)->items + AS_LIST(a)->len, AS_LIST(b)->items, sizeof(V) * AS_LIST(b)->len);
            AS_LIST(l)->len = AS_LIST(a)->len + AS_LIST(b)->len;
            return l;
        }
        if (ta == T_TUPLE && tb == T_TUPLE) {
            V t = mk_tuple(AS_TUPLE(a)->len + AS_TUPLE(b)->len);
            memcpy(AS_TUPLE(t)->items, AS_TUPLE(a)->items, sizeof(V) * AS_TUPLE(a)->len);
            memcpy(AS_TUPLE(t)->items + AS_TUPLE(a)->len, AS_TUPLE(b)->items, sizeof(V) * AS_TUPLE(b)->len);
            return t;
        }
        break;
    case T_MINUS:
        if (ta == T_INT && tb == T_INT)
            return mk_int(sub64(AS_INT(a), AS_INT(b)));
        break;
    case T_STAR:
        if (ta == T_INT && tb == T_INT)
            return mk_int(mul64(AS_INT(a), AS_INT(b)));
        if (tb == T_INT && (ta == T_STRING || ta == T_LIST || ta == T_TUPLE))
            return repeat(a, AS_INT(b));
        if (ta == T_INT && (tb == T_STRING || tb == T_LIST || tb == T_TUPLE))
            return repeat(b, AS_INT(a));
        break;
    case T_SLASH:
        if (ta == T_INT && tb == T_INT)
            star_error("floating-point division is not supported (ints only; use //)");
        break;
    case T_SLASHSLASH:
        if (ta == T_INT && tb == T_INT)
            return mk_int(floordiv(AS_INT(a), AS_INT(b)));
        break;
    case T_PERCENT:
        if (ta == T_INT && tb == T_INT)
            return mk_int(floormod(AS_INT(a), AS_INT(b)));
        if (ta == T_STRING)
            return string_percent(AS_STR(a), b);
        break;
    case T_AMP:
        if (ta == T_INT && tb == T_INT)
            return mk_int(AS_INT(a) & AS_INT(b));
        break;
    case T_PIPE:
        if (ta == T_INT && tb == T_INT)
            return mk_int(AS_INT(a) | AS_INT(b));
        if (ta == T_DICT && tb == T_DICT) {
            V d = mk_dict();
            int i;
            for (i = 0; i < AS_DICT(a)->nents; i++)
                if (AS_DICT(a)->ents[i].key)
                    dict_set(d, AS_DICT(a)->ents[i].key, AS_DICT(a)->ents[i].val);
            for (i = 0; i < AS_DICT(b)->nents; i++)
                if (AS_DICT(b)->ents[i].key)
                    dict_set(d, AS_DICT(b)->ents[i].key, AS_DICT(b)->ents[i].val);
            return d;
        }
        break;
    case T_CIRCUMFLEX:
        if (ta == T_INT && tb == T_INT)
            return mk_int(AS_INT(a) ^ AS_INT(b));
        break;
    case T_LTLT: case T_GTGT:
        if (ta == T_INT && tb == T_INT) {
            int64_t x = AS_INT(a), n = AS_INT(b);
            if (n < 0)
                star_error("negative shift count: %lld", (long long)n);
            if (op == T_GTGT)
                return mk_int(n >= 63 ? (x < 0 ? -1 : 0) : x >> n);
            if (n >= 512)
                star_error("shift count too large: %lld", (long long)n);
            if (x == 0)
                return mk_int(0);
            if (n >= 63 || (x > 0 ? x > (INT64_MAX >> n) : x < (INT64_MIN >> n)))
                star_error("int overflow in %lld << %lld (ints are 64-bit)", (long long)x, (long long)n);
            return mk_int((int64_t)((uint64_t)x << n));
        }
        break;
    case T_IN:
        return mk_bool(value_in(a, b));
    case T_NOT_IN:
        return mk_bool(!value_in(a, b));
    case T_EQL: case T_NEQ: case T_LT: case T_GT: case T_LE: case T_GE:
        return mk_bool(compare(a, b, op));
    }
    star_error("unknown binary op: %s %s %s", type_name(a), token_str(op), type_name(b));
    return NULL;
}

/* -------------------------------------------------------------- indexing -- */

static int64_t check_index(V x, int64_t i, int len)
{
    int64_t orig = i;
    if (i < 0)
        i += len;
    if (i < 0 || i >= len) {
        if (len == 0)
            star_error("index %lld out of range: empty %s", (long long)orig, type_name(x));
        star_error("%sindex %lld out of range [%d:%d]", TYPE(x) == T_LIST ? "list " : "",
                   (long long)orig, -len, len - 1);
    }
    return i;
}

V index_value(V x, V i)
{
    if (TYPE(x) == T_STRVIEW && ((StrView *)x)->codepoints)
        star_error("unhandled index operation %s[%s]", type_name(x), type_name(i));
    switch (TYPE(x)) {
    case T_LIST: case T_TUPLE: case T_STRING: case T_RANGE: case T_STRVIEW: {
        int64_t k;
        int len = seq_len(x);
        if (TYPE(i) != T_INT)
            star_error("%s index: got %s, want int", type_name(x), type_name(i));
        k = check_index(x, AS_INT(i), len);
        switch (TYPE(x)) {
        case T_STRVIEW:
            if (((StrView *)x)->ords)
                return mk_int((unsigned char)((StrView *)x)->s->s[k]);
            return mk_str(((StrView *)x)->s->s + k, 1);
        case T_LIST: return AS_LIST(x)->items[k];
        case T_TUPLE: return AS_TUPLE(x)->items[k];
        case T_STRING: return mk_str(AS_STR(x)->s + k, 1);
        case T_RANGE: return mk_int(((Range *)x)->start + k * ((Range *)x)->step);
        }
    }
    case T_DICT: {
        V v = dict_get(x, i);
        if (!v) {
            Buf b;
            buf_init(&b);
            repr_to(&b, i);
            star_error("key %s not in dict", buf_cstr(&b));
        }
        return v;
    }
    }
    star_error("unhandled index operation %s[%s]", type_name(x), type_name(i));
    return NULL;
}

static int64_t slice_bound(V v, int64_t def, int len, int64_t step, const char *which)
{
    int64_t i;
    if (!v || v == None)
        return def;
    if (TYPE(v) != T_INT)
        star_error("invalid %s index: got %s, want int", which, type_name(v));
    i = AS_INT(v);
    if (i < 0) {
        i += len;
        if (i < 0)
            i = step < 0 ? -1 : 0;
    } else if (step < 0 && i >= len) {
        i = len - 1;
    } else if (step > 0 && i > len) {
        i = len;
    }
    return i;
}

static V slice_value(V x, V lo, V hi, V stepv)
{
    int64_t step = 1, start, stop, i;
    int len = seq_len(x);
    V out;
    if (TYPE(x) != T_LIST && TYPE(x) != T_TUPLE && TYPE(x) != T_STRING && TYPE(x) != T_RANGE)
        star_error("invalid slice operand %s", type_name(x));
    if (stepv && stepv != None) {
        if (TYPE(stepv) != T_INT)
            star_error("invalid slice step: got %s, want int", type_name(stepv));
        step = AS_INT(stepv);
        if (step == 0)
            star_error("zero is not a valid slice step");
    }
    if (step > 0) {
        start = slice_bound(lo, 0, len, step, "start");
        stop = slice_bound(hi, len, len, step, "end");
    } else {
        start = slice_bound(lo, len - 1, len, step, "start");
        stop = slice_bound(hi, -1, len, step, "end");
    }
    if (TYPE(x) == T_RANGE) {
        Range *r = (Range *)x;
        return mk_range(r->start + start * r->step, r->start + stop * r->step, r->step * step);
    }
    if (TYPE(x) == T_STRING) {
        Buf b;
        buf_init(&b);
        if (step == 1)
            return mk_str(AS_STR(x)->s + start, stop > start ? (int)(stop - start) : 0);
        for (i = start; step > 0 ? i < stop : i > stop; i += step)
            buf_putc(&b, AS_STR(x)->s[i]);
        return mk_str(b.p ? b.p : "", b.len);
    }
    out = mk_list(0);
    for (i = start; step > 0 ? i < stop : i > stop; i += step)
        list_append(out, TYPE(x) == T_LIST ? AS_LIST(x)->items[i] : AS_TUPLE(x)->items[i]);
    if (TYPE(x) == T_TUPLE) {
        V t = mk_tuple(AS_LIST(out)->len);
        memcpy(AS_TUPLE(t)->items, AS_LIST(out)->items, sizeof(V) * AS_LIST(out)->len);
        return t;
    }
    return out;
}

/* ------------------------------------------------------------ attributes -- */

static int edit_distance(const char *a, const char *b)
{
    int la = strlen(a), lb = strlen(b), i, j;
    int d[64][64];
    if (la >= 63 || lb >= 63)
        return 99;
    for (i = 0; i <= la; i++)
        d[i][0] = i;
    for (j = 0; j <= lb; j++)
        d[0][j] = j;
    for (i = 1; i <= la; i++)
        for (j = 1; j <= lb; j++) {
            int c = d[i - 1][j - 1] + (a[i - 1] != b[j - 1]);
            if (d[i - 1][j] + 1 < c) c = d[i - 1][j] + 1;
            if (d[i][j - 1] + 1 < c) c = d[i][j - 1] + 1;
            d[i][j] = c;
        }
    return d[la][lb];
}

/* nearest candidate within a small edit distance, or NULL */
const char *did_you_mean(const char *name, V candidates)
{
    const char *best = NULL;
    int bestd = 1 + (int)strlen(name) / 4, i;
    if (bestd > 3)
        bestd = 3;
    bestd++;
    for (i = 0; i < AS_LIST(candidates)->len; i++) {
        const char *c = AS_STR(AS_LIST(candidates)->items[i])->s;
        int d = edit_distance(name, c);
        if (d < bestd) {
            bestd = d;
            best = c;
        }
    }
    return best;
}

V get_attr(V v, Str *name, int want_error)
{
    V m;
    if (TYPE(v) == T_STRUCT) {
        Struct *s = (Struct *)v;
        int i;
        for (i = 0; i < s->n; i++)
            if (s->names[i] == name)
                return s->vals[i];
    }
    m = builtin_method(v, name);
    if (m)
        return m;
    if (!want_error)
        return NULL;
    {
        V cands = mk_list(0);
        const char *sug;
        if (TYPE(v) == T_STRUCT) {
            Struct *s = (Struct *)v;
            int i;
            for (i = 0; i < s->n; i++)
                list_append(cands, (V)s->names[i]);
        }
        method_names(v, cands);
        sug = did_you_mean(name->s, cands);
        if (sug)
            star_error("%s has no .%s field or method (did you mean .%s?)", type_name(v), name->s, sug);
        star_error("%s has no .%s field or method", type_name(v), name->s);
    }
    return NULL;
}

/* ------------------------------------------------------------ identifiers -- */

static V lookup_ident(Frame *fr, Node *id)
{
    V v;
    switch (id->scope) {
    case S_LOCAL:
        v = fr->locals[id->index];
        if (v && fr->info->iscell[id->index])
            v = ((Cell *)v)->v;
        if (!v)
            star_error("local variable %s referenced before assignment", id->s->s);
        return v;
    case S_FREE:
        v = fr->free[id->index]->v;
        if (!v)
            star_error("local variable %s referenced before assignment", id->s->s);
        return v;
    case S_GLOBAL:
        v = fr->module->globals[id->index];
        if (!v)
            star_error("%s variable %s referenced before assignment",
                       fr->module->exported[id->index] == 2 ? "local" : "global", id->s->s);
        return v;
    case S_PREDECLARED:
        v = predeclared ? dict_get((V)predeclared, (V)id->s) : NULL;
        if (!v)
            star_error("undefined: %s", id->s->s);
        return v;
    case S_UNIVERSAL:
        v = universe_lookup(id->s);
        if (!v)
            star_error("undefined: %s", id->s->s);
        return v;
    }
    fatal("unresolved identifier %s", id->s->s);
    return NULL;
}

static void set_ident(Frame *fr, Node *id, V v)
{
    switch (id->scope) {
    case S_LOCAL:
        if (fr->info->iscell[id->index])
            ((Cell *)fr->locals[id->index])->v = v;
        else
            fr->locals[id->index] = v;
        return;
    case S_FREE:
        fr->free[id->index]->v = v;
        return;
    case S_GLOBAL:
        fr->module->globals[id->index] = v;
        return;
    }
    fatal("cannot assign to %s (scope %d)", id->s->s, id->scope);
}

/* ------------------------------------------------------------ assignment -- */

static void set_index(V x, V i, V v)
{
    switch (TYPE(x)) {
    case T_LIST: {
        int64_t k;
        list_check_mutable(x, "assign to element of");
        if (TYPE(i) != T_INT)
            star_error("list index: got %s, want int", type_name(i));
        k = check_index(x, AS_INT(i), AS_LIST(x)->len);
        AS_LIST(x)->items[k] = v;
        return;
    }
    case T_DICT:
        dict_check_mutable(x, "insert into");
        dict_set(x, i, v);
        return;
    }
    star_error("%s value does not support item assignment", type_name(x));
}

static void assign(Frame *fr, Node *t, V v)
{
    int i;
    switch (t->kind) {
    case N_IDENT:
        set_ident(fr, t, v);
        return;
    case N_PAREN:
        assign(fr, t->a, v);
        return;
    case N_INDEX: {
        V x = eval(fr, t->a);
        V k = eval(fr, t->b);
        fr->line = t->line;
        fr->col = t->col;
        set_index(x, k, v);
        return;
    }
    case N_DOT: {
        V x = eval(fr, t->a);
        fr->line = t->line;
        fr->col = t->col;
        star_error("can't assign to .%s field of %s", t->s->s, type_name(x));
        return;
    }
    case N_TUPLE: case N_LIST: {
        int n = seq_len(v);
        V *items;
        if (TYPE(v) != T_LIST && TYPE(v) != T_TUPLE && TYPE(v) != T_DICT && TYPE(v) != T_RANGE)
            star_error("got %s in sequence assignment", type_name(v));
        if (n > t->n)
            star_error("too many values to unpack (got %d, want %d)", n, t->n);
        if (n < t->n)
            star_error("too few values to unpack (got %d, want %d)", n, t->n);
        {
            V l = to_list(v);
            items = AS_LIST(l)->items;
        }
        for (i = 0; i < t->n; i++)
            assign(fr, t->list[i], items[i]);
        return;
    }
    }
    fatal("bad assignment target");
}

/* ----------------------------------------------------------- expressions -- */

static void build_args(Frame *fr, Node *call, Args *a)
{
    int i, np = 0, nk = 0, cap = call->n + 4;
    memset(a, 0, sizeof *a);
    a->pos = arena_alloc(sizeof(V) * cap);
    a->kwnames = arena_alloc(sizeof(Str *) * cap);
    a->kwvals = arena_alloc(sizeof(V) * cap);
    for (i = 0; i < call->n; i++) {
        Node *arg = call->list[i];
        if (arg->kind == N_KWARG) {
            if (nk >= cap - 1) {
                a->kwnames = arena_grow(a->kwnames, sizeof(Str *) * cap, sizeof(Str *) * cap * 2);
                a->kwvals = arena_grow(a->kwvals, sizeof(V) * cap, sizeof(V) * cap * 2);
                a->pos = arena_grow(a->pos, sizeof(V) * cap, sizeof(V) * cap * 2);
                cap *= 2;
            }
            a->kwnames[nk] = arg->s;
            a->kwvals[nk] = eval(fr, arg->a);
            nk++;
        } else if (arg->kind == N_STARARG) {
            V s = eval(fr, arg->a);
            Iter it;
            V x;
            if (!iterable(s)) {
                fr->line = arg->line;
                fr->col = arg->col;
                star_error("argument after * must be iterable, not %s", type_name(s));
            }
            iter_start(&it, s);
            while ((x = iter_next(&it)) != NULL) {
                if (np >= cap - 1) {
                    a->pos = arena_grow(a->pos, sizeof(V) * cap, sizeof(V) * cap * 2);
                    a->kwnames = arena_grow(a->kwnames, sizeof(Str *) * cap, sizeof(Str *) * cap * 2);
                    a->kwvals = arena_grow(a->kwvals, sizeof(V) * cap, sizeof(V) * cap * 2);
                    cap *= 2;
                }
                a->pos[np++] = x;
            }
            iter_done(&it);
        } else if (arg->kind == N_STARSTARARG) {
            V d = eval(fr, arg->a);
            int j;
            if (TYPE(d) != T_DICT) {
                fr->line = arg->line;
                fr->col = arg->col;
                star_error("argument after ** must be a mapping, not %s", type_name(d));
            }
            for (j = 0; j < AS_DICT(d)->nents; j++) {
                DEntry *e = &AS_DICT(d)->ents[j];
                if (!e->key)
                    continue;
                if (TYPE(e->key) != T_STRING)
                    star_error("keywords must be strings, not %s", type_name(e->key));
                if (nk >= cap - 1) {
                    a->kwnames = arena_grow(a->kwnames, sizeof(Str *) * cap, sizeof(Str *) * cap * 2);
                    a->kwvals = arena_grow(a->kwvals, sizeof(V) * cap, sizeof(V) * cap * 2);
                    a->pos = arena_grow(a->pos, sizeof(V) * cap, sizeof(V) * cap * 2);
                    cap *= 2;
                }
                /* duplicates are the callee's to report, as in starlark-go */
                a->kwnames[nk] = intern_n(AS_STR(e->key)->s, AS_STR(e->key)->len);
                a->kwvals[nk] = e->val;
                nk++;
            }
        } else {
            if (np >= cap - 1) {
                a->pos = arena_grow(a->pos, sizeof(V) * cap, sizeof(V) * cap * 2);
                a->kwnames = arena_grow(a->kwnames, sizeof(Str *) * cap, sizeof(Str *) * cap * 2);
                a->kwvals = arena_grow(a->kwvals, sizeof(V) * cap, sizeof(V) * cap * 2);
                cap *= 2;
            }
            a->pos[np++] = eval(fr, arg);
        }
    }
    a->npos = np;
    a->nkw = nk;
}

static void comp_clause(Frame *fr, Node *comp, int ci, V out)
{
    Node *cl;
    if (ci == comp->n) {
        if (comp->op == T_LBRACK) {
            list_append(out, eval(fr, comp->a));
        } else {
            V k = eval(fr, comp->a->a);
            V v = eval(fr, comp->a->b);
            fr->line = comp->a->line;
            fr->col = comp->a->col;
            dict_set(out, k, v);
        }
        return;
    }
    cl = comp->list[ci];
    if (cl->kind == N_IFCLAUSE) {
        if (truth(eval(fr, cl->a)))
            comp_clause(fr, comp, ci + 1, out);
        return;
    }
    {
        V seq = eval(fr, cl->b);
        Iter it;
        V x;
        fr->line = cl->line;
        fr->col = cl->col;
        iter_start(&it, seq);
        while ((x = iter_next(&it)) != NULL) {
            assign(fr, cl->a, x);
            comp_clause(fr, comp, ci + 1, out);
        }
        iter_done(&it);
    }
}

static V make_function(Frame *fr, FuncInfo *fi)
{
    Function *f = arena_alloc(sizeof(Function));
    int i;
    f->type = T_FUNCTION;
    f->info = fi;
    f->module = fr->module;
    f->defaults = arena_alloc(sizeof(V) * (fi->nparams + 1));
    for (i = 0; i < fi->nparams; i++)
        if (fi->params[i]->kind == N_PARAM && fi->params[i]->a)
            f->defaults[i] = eval(fr, fi->params[i]->a);
    f->free = arena_alloc(sizeof(Cell *) * (fi->nfree + 1));
    for (i = 0; i < fi->nfree; i++) {
        FreeVar *fv = &fi->free[i];
        f->free[i] = fv->from_free ? fr->free[fv->idx] : (Cell *)fr->locals[fv->idx];
    }
    return (V)f;
}

static V eval(Frame *fr, Node *e)
{
    int i;
    switch (e->kind) {
    case N_IDENT:
        fr->line = e->line;
        fr->col = e->col;
        return lookup_ident(fr, e);
    case N_INT:
        return mk_int(e->ival);
    case N_STRING:
        return (V)e->s;
    case N_PAREN:
        return eval(fr, e->a);
    case N_LIST: {
        V l = mk_list(e->n);
        for (i = 0; i < e->n; i++)
            AS_LIST(l)->items[i] = eval(fr, e->list[i]);
        AS_LIST(l)->len = e->n;
        return l;
    }
    case N_TUPLE: {
        V t = mk_tuple(e->n);
        for (i = 0; i < e->n; i++)
            AS_TUPLE(t)->items[i] = eval(fr, e->list[i]);
        return t;
    }
    case N_DICT: {
        V d = mk_dict();
        for (i = 0; i < e->n; i++) {
            V k = eval(fr, e->list[i]->a);
            V v = eval(fr, e->list[i]->b);
            fr->line = e->list[i]->line;
            fr->col = e->list[i]->col;
            if (dict_get(d, k)) {
                Buf b;
                buf_init(&b);
                repr_to(&b, k);
                star_error("duplicate key: %s", buf_cstr(&b));
            }
            dict_set(d, k, v);
        }
        return d;
    }
    case N_COMP: {
        V out = e->op == T_LBRACK ? mk_list(0) : mk_dict();
        comp_clause(fr, e, 0, out);
        return out;
    }
    case N_UNARY: {
        V x;
        if (e->op == T_NOT)
            return mk_bool(!truth(eval(fr, e->a)));
        x = eval(fr, e->a);
        fr->line = e->line;
        fr->col = e->col;
        if (TYPE(x) == T_INT) {
            switch (e->op) {
            case T_MINUS:
                if (AS_INT(x) == INT64_MIN)
                    star_error("int overflow in -%lld (ints are 64-bit)", (long long)AS_INT(x));
                return mk_int(-AS_INT(x));
            case T_PLUS:
                return x;
            case T_TILDE:
                return mk_int(~AS_INT(x));
            }
        }
        star_error("unknown unary op: %s %s", token_str(e->op), type_name(x));
        return NULL;
    }
    case N_BINARY: {
        V a, b;
        if (e->op == T_AND) {
            a = eval(fr, e->a);
            return truth(a) ? eval(fr, e->b) : a;
        }
        if (e->op == T_OR) {
            a = eval(fr, e->a);
            return truth(a) ? a : eval(fr, e->b);
        }
        a = eval(fr, e->a);
        b = eval(fr, e->b);
        fr->line = e->line;
        fr->col = e->col;
        return binary_op(e->op, a, b);
    }
    case N_COND:
        return truth(eval(fr, e->b)) ? eval(fr, e->a) : eval(fr, e->c);
    case N_LAMBDA:
        return make_function(fr, e->fn);
    case N_CALL: {
        V fn = eval(fr, e->a);
        Args a;
        build_args(fr, e, &a);
        fr->line = e->line;
        fr->col = e->col;
        return call_value(fn, &a);
    }
    case N_DOT: {
        V x = eval(fr, e->a);
        fr->line = e->line;
        fr->col = e->col;
        return get_attr(x, e->s, 1);
    }
    case N_INDEX: {
        V x = eval(fr, e->a);
        V k = eval(fr, e->b);
        fr->line = e->line;
        fr->col = e->col;
        return index_value(x, k);
    }
    case N_SLICE: {
        V x = eval(fr, e->a);
        V lo = e->b ? eval(fr, e->b) : NULL;
        V hi = e->c ? eval(fr, e->c) : NULL;
        V st = e->d ? eval(fr, e->d) : NULL;
        fr->line = e->line;
        fr->col = e->col;
        return slice_value(x, lo, hi, st);
    }
    }
    fatal("eval: unexpected node kind %d", e->kind);
    return NULL;
}

/* ------------------------------------------------------------ statements -- */

static void exec_load(Frame *fr, Node *st)
{
    Module *m;
    int i;
    fr->line = st->line;
    fr->col = st->col;
    m = load_module(st->a->s->s, fr->info->filename ? fr->info->filename : "");
    for (i = 0; i < st->n; i++) {
        Node *kv = st->list[i];
        Str *want = intern_n(kv->a->s->s, kv->a->s->len);
        int j;
        V v = NULL;
        fr->line = kv->line;
        fr->col = kv->col;
        if (want->s[0] == '_')
            star_error("load: cannot load %s: names starting with _ are private", want->s);
        for (j = 0; j < m->nglobals; j++)
            if (m->gnames[j] == want && m->exported[j])
                v = m->globals[j];
        if (!v) {
            V cands = mk_list(0);
            const char *sug;
            for (j = 0; j < m->nglobals; j++)
                if (m->exported[j])
                    list_append(cands, (V)m->gnames[j]);
            sug = did_you_mean(want->s, cands);
            if (sug)
                star_error("load: name %s not found in module %s (did you mean %s?)", want->s, m->name, sug);
            star_error("load: name %s not found in module %s", want->s, m->name);
        }
        set_ident(fr, kv, v);
    }
}

/* x op= y: lists extend and dicts update in place; everything else rebinds */
static V inplace_op(int op, V old, V y)
{
    int i;
    if (op == T_PLUS && TYPE(old) == T_LIST) {
        V items;
        list_check_mutable(old, "apply += to");
        if (!iterable(y))
            star_error("unknown binary op: list + %s", type_name(y));
        items = to_list(y);
        for (i = 0; i < AS_LIST(items)->len; i++)
            list_append(old, AS_LIST(items)->items[i]);
        return old;
    }
    if (op == T_PIPE && TYPE(old) == T_DICT && TYPE(y) == T_DICT) {
        Dict *d = AS_DICT(y);
        dict_check_mutable(old, "apply |= to");
        for (i = 0; i < d->nents; i++)
            if (d->ents[i].key)
                dict_set(old, d->ents[i].key, d->ents[i].val);
        return old;
    }
    return binary_op(op, old, y);
}

static void augassign(Frame *fr, Node *st)
{
    Node *t = st->a;
    while (t->kind == N_PAREN)
        t = t->a;
    if (t->kind == N_INDEX) {
        V x = eval(fr, t->a);
        V k = eval(fr, t->b);
        V old, y, r;
        fr->line = t->line;
        fr->col = t->col;
        old = index_value(x, k);
        y = eval(fr, st->b);
        fr->line = st->line;
        fr->col = st->col;
        r = inplace_op(st->op, old, y);
        set_index(x, k, r);
        return;
    }
    if (t->kind == N_DOT) {
        V x = eval(fr, t->a);
        (void)get_attr(x, t->s, 1);
        eval(fr, st->b);
        fr->line = t->line;
        fr->col = t->col;
        star_error("can't assign to .%s field of %s", t->s->s, type_name(x));
    }
    {
        V old = lookup_ident(fr, t);
        V y = eval(fr, st->b);
        fr->line = st->line;
        fr->col = st->col;
        set_ident(fr, t, inplace_op(st->op, old, y));
    }
}

static int exec_stmts(Frame *fr, Node **s, int n, V *ret)
{
    int i;
    for (i = 0; i < n; i++) {
        Node *st = s[i];
        fr->line = st->line;
        fr->col = st->col;
        switch (st->kind) {
        case N_EXPRSTMT:
            eval(fr, st->a);
            break;
        case N_ASSIGN: {
            V v = eval(fr, st->b);
            fr->line = st->line;
            fr->col = st->col;
            assign(fr, st->a, v);
            break;
        }
        case N_AUGASSIGN:
            augassign(fr, st);
            break;
        case N_DEF: {
            V f = make_function(fr, st->fn);
            Node id;
            memset(&id, 0, sizeof id);
            id.kind = N_IDENT;
            id.s = st->s;
            id.scope = st->scope;
            id.index = st->index;
            set_ident(fr, &id, f);
            break;
        }
        case N_IF: {
            int cf;
            if (truth(eval(fr, st->a)))
                cf = exec_stmts(fr, st->list, st->n, ret);
            else
                cf = exec_stmts(fr, st->list2, st->n2, ret);
            if (cf != CF_NORMAL)
                return cf;
            break;
        }
        case N_FOR: {
            V seq = eval(fr, st->b);
            Iter it;
            V x;
            int cf = CF_NORMAL;
            fr->line = st->line;
            fr->col = st->col;
            iter_start(&it, seq);
            while ((x = iter_next(&it)) != NULL) {
                assign(fr, st->a, x);
                cf = exec_stmts(fr, st->list, st->n, ret);
                if (cf == CF_BREAK || cf == CF_RETURN)
                    break;
                cf = CF_NORMAL;
            }
            iter_done(&it);
            if (cf == CF_RETURN)
                return cf;
            break;
        }
        case N_WHILE: {
            int cf = CF_NORMAL;
            while (truth(eval(fr, st->a))) {
                cf = exec_stmts(fr, st->list, st->n, ret);
                if (cf == CF_BREAK || cf == CF_RETURN)
                    break;
                cf = CF_NORMAL;
            }
            if (cf == CF_RETURN)
                return cf;
            break;
        }
        case N_RETURN:
            *ret = st->a ? eval(fr, st->a) : None;
            return CF_RETURN;
        case N_BREAK:
            return CF_BREAK;
        case N_CONTINUE:
            return CF_CONTINUE;
        case N_PASS:
            break;
        case N_LOAD:
            exec_load(fr, st);
            break;
        default:
            fatal("exec: unexpected statement kind %d", st->kind);
        }
    }
    return CF_NORMAL;
}

/* --------------------------------------------------------------- modules -- */

static Module **modules;
static int nmodules, modcap;

static int is_predeclared_cb(Str *name)
{
    return predeclared && dict_get((V)predeclared, (V)name) != NULL;
}

static char *read_file(const char *path, int *len)
{
    FILE *f = fopen(path, "rb");
    Buf b;
    char tmp[8192];
    size_t n;
    if (!f)
        return NULL;
    buf_init(&b);
    while ((n = fread(tmp, 1, sizeof tmp, f)) > 0)
        buf_put(&b, tmp, n);
    fclose(f);
    *len = (int)b.len;
    return buf_cstr(&b);
}

char *read_file_or_die(const char *path, int *len)
{
    char *s = read_file(path, len);
    if (!s)
        star_error("cannot read %s", path);
    return s;
}

/* Parse and resolve a source text into a fresh Module; static errors are
 * reported as one runtime error (first message), all messages to stderr
 * unless quiet. */
Module *compile_module(const char *name, const char *filename, const char *src, int len,
                       ErrList *errs)
{
    Module *m = arena_alloc(sizeof(Module));
    Node *file;
    m->type = T_MODULE;
    m->name = arena_strdup(name);
    m->filename = arena_strdup(filename);
    file = parse_file(m->filename, src, len, errs);
    if (!file)
        return NULL;
    if (!resolve_file(file, m->filename, &m->toplevel, &m->gnames, &m->nglobals,
                      &m->exported, is_predeclared_cb, errs))
        return NULL;
    m->file = file;
    m->globals = arena_alloc(sizeof(V) * (m->nglobals + 1));
    return m;
}

void exec_module(Module *m)
{
    Frame fr;
    FuncInfo *fi = m->toplevel;
    V ret = None;
    int i;
    memset(&fr, 0, sizeof fr);
    fr.parent = cur_frame;
    fr.info = fi;
    fr.module = m;
    fr.locals = arena_alloc(sizeof(V) * (fi->nlocals + 1));
    for (i = 0; i < fi->nlocals; i++) {
        if (fi->iscell[i]) {
            Cell *c = arena_alloc(sizeof(Cell));
            c->type = T_CELL;
            fr.locals[i] = (V)c;
        }
    }
    fr.line = 1;
    fr.col = 1;
    m->state = 1;
    cur_frame = &fr;
    call_depth++;
    exec_stmts(&fr, fi->body, fi->nbody, &ret);
    call_depth--;
    cur_frame = fr.parent;
    m->state = 2;
    for (i = 0; i < m->nglobals; i++)
        if (m->globals[i])
            freeze_value(m->globals[i]);
}

Module *load_module(const char *name, const char *from_file)
{
    char *path = module_path_hook ? module_path_hook(name, from_file) : arena_strdup(name);
    int i, len;
    char *src;
    ErrList errs;
    Module *m;
    if (!path)
        star_error("cannot load %s", name);
    for (i = 0; i < nmodules; i++) {
        if (strcmp(modules[i]->filename, path) == 0) {
            if (modules[i]->state == 1)
                star_error("cycle in load graph at %s", name);
            return modules[i];
        }
    }
    src = read_file(path, &len);
    if (!src)
        star_error("cannot load %s: no such file %s", name, path);
    memset(&errs, 0, sizeof errs);
    m = compile_module(name, path, src, len, &errs);
    if (!m) {
        for (i = 0; i < errs.n; i++)
            fprintf(stderr, "%s:%d:%d: %s\n", errs.pos[i].file, errs.pos[i].line,
                    errs.pos[i].col, errs.msg[i]);
        star_error("cannot load %s: %s:%d:%d: %s", name, errs.pos[0].file, errs.pos[0].line,
                   errs.pos[0].col, errs.msg[0]);
    }
    if (nmodules == modcap) {
        int nc = modcap ? modcap * 2 : 8;
        modules = arena_grow(modules, sizeof(Module *) * modcap, sizeof(Module *) * nc);
        modcap = nc;
    }
    modules[nmodules++] = m;
    exec_module(m);
    return m;
}

void reset_modules(void)
{
    nmodules = 0;
}

/* Every module this process loaded, in load order (for hashing). */
int loaded_modules(Module ***out)
{
    *out = modules;
    return nmodules;
}
