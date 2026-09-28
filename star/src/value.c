/* SPDX-License-Identifier: MIT
 * value.c -- the value model: constructors, truth, equality, ordering,
 * hashing, repr/str, lists, the insertion-ordered dict, iteration, freezing. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "star.h"

static Obj none_obj = {T_NONE};
static Bool true_obj = {T_BOOL, 1};
static Bool false_obj = {T_BOOL, 0};
V None = &none_obj;
V True = (V)&true_obj;
V False = (V)&false_obj;

/* small ints are shared */
static Int small_ints[512];

V mk_int(int64_t v)
{
    Int *i;
    if (v >= -256 && v < 256) {
        i = &small_ints[v + 256];
        i->type = T_INT;
        i->v = v;
        return (V)i;
    }
    i = arena_alloc(sizeof(Int));
    i->type = T_INT;
    i->v = v;
    return (V)i;
}

V mk_bool(int b)
{
    return b ? True : False;
}

V mk_str(const char *s, int len)
{
    Str *x = arena_alloc(sizeof(Str) + len);
    x->type = T_STRING;
    x->len = len;
    if (len)
        memcpy(x->s, s, len);
    x->s[len] = 0;
    return (V)x;
}

V mk_cstr(const char *s)
{
    return mk_str(s, strlen(s));
}

V mk_strf(const char *fmt, ...)
{
    va_list ap;
    char tmp[1024];
    int n;
    va_start(ap, fmt);
    n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n >= (int)sizeof tmp)
        n = sizeof tmp - 1;
    return mk_str(tmp, n);
}

V mk_list(int cap)
{
    List *l = arena_alloc(sizeof(List));
    l->type = T_LIST;
    if (cap > 0) {
        l->items = arena_alloc(sizeof(V) * cap);
        l->cap = cap;
    }
    return (V)l;
}

V mk_tuple(int n)
{
    Tuple *t = arena_alloc(sizeof(Tuple) + sizeof(V) * (n > 0 ? n - 1 : 0));
    t->type = T_TUPLE;
    t->len = n;
    return (V)t;
}

V mk_dict(void)
{
    Dict *d = arena_alloc(sizeof(Dict));
    d->type = T_DICT;
    return (V)d;
}

V mk_range(int64_t start, int64_t stop, int64_t step)
{
    Range *r = arena_alloc(sizeof(Range));
    r->type = T_RANGE;
    r->start = start;
    r->stop = stop;
    r->step = step;
    return (V)r;
}

V mk_builtin(const char *name, BuiltinFn fn, V recv)
{
    Builtin *b = arena_alloc(sizeof(Builtin));
    b->type = T_BUILTIN;
    b->name = name;
    b->fn = fn;
    b->recv = recv;
    return (V)b;
}

static int str_cmp(Str *a, Str *b)
{
    int n = a->len < b->len ? a->len : b->len;
    int c = memcmp(a->s, b->s, n);
    if (c)
        return c;
    return a->len - b->len;
}

V mk_struct(const char *ctor, int n, Str **names, V *vals)
{
    Struct *s = arena_alloc(sizeof(Struct));
    int i, j;
    s->type = T_STRUCT;
    s->ctor = ctor;
    s->n = n;
    s->names = arena_alloc(sizeof(Str *) * (n + 1));
    s->vals = arena_alloc(sizeof(V) * (n + 1));
    /* insertion sort by name; n is small */
    for (i = 0; i < n; i++) {
        for (j = i; j > 0 && str_cmp(s->names[j - 1], names[i]) > 0; j--) {
            s->names[j] = s->names[j - 1];
            s->vals[j] = s->vals[j - 1];
        }
        s->names[j] = names[i];
        s->vals[j] = vals[i];
    }
    return (V)s;
}

const char *type_name(V v)
{
    switch (TYPE(v)) {
    case T_NONE: return "NoneType";
    case T_BOOL: return "bool";
    case T_INT: return "int";
    case T_STRING: return "string";
    case T_LIST: return "list";
    case T_TUPLE: return "tuple";
    case T_DICT: return "dict";
    case T_RANGE: return "range";
    case T_FUNCTION: return "function";
    case T_BUILTIN: return "builtin_function_or_method";
    case T_STRUCT: return ((Struct *)v)->ctor;
    case T_MODULE: return "module";
    case T_STRVIEW:
        return ((StrView *)v)->codepoints ? "string.codepoints" : "string.elems";
    }
    return "?";
}

static int64_t range_len(Range *r)
{
    if (r->step > 0) {
        if (r->start >= r->stop)
            return 0;
        return (r->stop - r->start - 1) / r->step + 1;
    }
    if (r->start <= r->stop)
        return 0;
    return (r->start - r->stop - 1) / (-r->step) + 1;
}

int seq_len(V v)
{
    switch (TYPE(v)) {
    case T_STRING: return AS_STR(v)->len;
    case T_LIST: return AS_LIST(v)->len;
    case T_TUPLE: return AS_TUPLE(v)->len;
    case T_DICT: return AS_DICT(v)->count;
    case T_RANGE: return (int)range_len((Range *)v);
    case T_STRVIEW:
        if (!((StrView *)v)->codepoints)
            return ((StrView *)v)->s->len;
        return -1;
    }
    return -1;
}

int truth(V v)
{
    switch (TYPE(v)) {
    case T_NONE: return 0;
    case T_BOOL: return ((Bool *)v)->v;
    case T_INT: return AS_INT(v) != 0;
    case T_STRING: case T_LIST: case T_TUPLE: case T_DICT: case T_RANGE:
        return seq_len(v) != 0;
    }
    return 1;
}

/* ------------------------------------------------------------- hashing -- */

static uint32_t mix(uint32_t h, uint32_t x)
{
    h ^= x + 0x9e3779b9u + (h << 6) + (h >> 2);
    return h;
}

uint32_t hash_value(V v)
{
    switch (TYPE(v)) {
    case T_NONE: return 0;
    case T_BOOL: return ((Bool *)v)->v ? 1231 : 1237;
    case T_INT: {
        uint64_t x = (uint64_t)AS_INT(v);
        return (uint32_t)(x ^ (x >> 32)) * 2654435761u;
    }
    case T_STRING: {
        Str *s = AS_STR(v);
        if (!s->hash) {
            uint32_t h = 2166136261u;
            int i;
            for (i = 0; i < s->len; i++) {
                h ^= (unsigned char)s->s[i];
                h *= 16777619u;
            }
            s->hash = h ? h : 1;
        }
        return s->hash;
    }
    case T_TUPLE: {
        Tuple *t = AS_TUPLE(v);
        uint32_t h = 0x345678;
        int i;
        for (i = 0; i < t->len; i++)
            h = mix(h, hash_value(t->items[i]));
        return h;
    }
    case T_FUNCTION: case T_BUILTIN:
        return (uint32_t)(uintptr_t)v * 2654435761u;
    case T_STRUCT: {
        Struct *s = (Struct *)v;
        uint32_t h = 0x9876;
        int i;
        if (strcmp(s->ctor, "module") == 0)
            star_error("unhashable: module");
        for (i = 0; i < s->n; i++) {
            h = mix(h, hash_value((V)s->names[i]));
            h = mix(h, hash_value(s->vals[i]));
        }
        return h;
    }
    case T_RANGE:
        star_error("unhashable: range");
    }
    star_error("unhashable type: %s", type_name(v));
    return 0;
}

int hashable(V v)
{
    int i;
    switch (TYPE(v)) {
    case T_LIST: case T_DICT: case T_RANGE: case T_STRVIEW:
        return 0;
    case T_TUPLE:
        for (i = 0; i < AS_TUPLE(v)->len; i++)
            if (!hashable(AS_TUPLE(v)->items[i]))
                return 0;
        return 1;
    }
    return 1;
}

/* ------------------------------------------------------------ equality -- */

static int range_equal(Range *a, Range *b)
{
    int64_t la = range_len(a), lb = range_len(b);
    if (la != lb)
        return 0;
    if (la == 0)
        return 1;
    if (a->start != b->start)
        return 0;
    if (la == 1)
        return 1;
    return a->step == b->step;
}

int eq_depth;

static int equal_rec(V a, V b);

/* starlark-go's CompareLimit: containers nest at most this deep in == and <.
 * Kept identical so that what star accepts, other backends accept. */
#define COMPARE_LIMIT 10

int equal(V a, V b)
{
    int r;
    if (a == b && TYPE(a) != T_LIST && TYPE(a) != T_DICT && TYPE(a) != T_TUPLE)
        return 1;
    if (++eq_depth > COMPARE_LIMIT) {
        eq_depth = 0;
        star_error("comparison exceeded maximum recursion depth");
    }
    r = equal_rec(a, b);
    eq_depth--;
    return r;
}

static int equal_rec(V a, V b)
{
    int i;
    if (TYPE(a) != TYPE(b))
        return 0;
    switch (TYPE(a)) {
    case T_NONE: return 1;
    case T_BOOL: return ((Bool *)a)->v == ((Bool *)b)->v;
    case T_INT: return AS_INT(a) == AS_INT(b);
    case T_STRING:
        return AS_STR(a)->len == AS_STR(b)->len &&
               memcmp(AS_STR(a)->s, AS_STR(b)->s, AS_STR(a)->len) == 0;
    case T_LIST: {
        List *x = AS_LIST(a), *y = AS_LIST(b);
        if (x->len != y->len)
            return 0;
        for (i = 0; i < x->len; i++)
            if (!equal(x->items[i], y->items[i]))
                return 0;
        return 1;
    }
    case T_TUPLE: {
        Tuple *x = AS_TUPLE(a), *y = AS_TUPLE(b);
        if (x->len != y->len)
            return 0;
        for (i = 0; i < x->len; i++)
            if (!equal(x->items[i], y->items[i]))
                return 0;
        return 1;
    }
    case T_DICT: {
        Dict *x = AS_DICT(a), *y = AS_DICT(b);
        if (x->count != y->count)
            return 0;
        for (i = 0; i < x->nents; i++) {
            V o;
            if (!x->ents[i].key)
                continue;
            o = dict_get(b, x->ents[i].key);
            if (!o || !equal(x->ents[i].val, o))
                return 0;
        }
        return 1;
    }
    case T_RANGE:
        return range_equal((Range *)a, (Range *)b);
    case T_STRUCT: {
        Struct *x = (Struct *)a, *y = (Struct *)b;
        if (strcmp(x->ctor, y->ctor) != 0 || x->n != y->n)
            return 0;
        for (i = 0; i < x->n; i++)
            if (x->names[i] != y->names[i] || !equal(x->vals[i], y->vals[i]))
                return 0;
        return 1;
    }
    case T_BUILTIN: {
        Builtin *x = (Builtin *)a, *y = (Builtin *)b;
        return x->fn == y->fn && x->recv && y->recv && x->recv == y->recv &&
               strcmp(x->name, y->name) == 0;
    }
    }
    return 0;
}

static const char *cmp_op_str(int op)
{
    switch (op) {
    case T_LT: return "<";
    case T_GT: return ">";
    case T_LE: return "<=";
    case T_GE: return ">=";
    }
    return "?";
}

/* three-way comparison of two ordered values; errors if not comparable */
static int order3_rec(V a, V b, int op);

static int order3(V a, V b, int op)
{
    int r;
    if (++eq_depth > COMPARE_LIMIT) {
        eq_depth = 0;
        star_error("comparison exceeded maximum recursion depth");
    }
    r = order3_rec(a, b, op);
    eq_depth--;
    return r;
}

static int order3_rec(V a, V b, int op)
{
    int i;
    if (TYPE(a) != TYPE(b))
        goto bad;
    switch (TYPE(a)) {
    case T_INT:
        return AS_INT(a) < AS_INT(b) ? -1 : AS_INT(a) > AS_INT(b);
    case T_BOOL:
        return ((Bool *)a)->v - ((Bool *)b)->v;
    case T_STRING:
        return str_cmp(AS_STR(a), AS_STR(b));
    case T_LIST: case T_TUPLE: {
        int la = seq_len(a), lb = seq_len(b);
        V *xa = TYPE(a) == T_LIST ? AS_LIST(a)->items : AS_TUPLE(a)->items;
        V *xb = TYPE(b) == T_LIST ? AS_LIST(b)->items : AS_TUPLE(b)->items;
        for (i = 0; i < la && i < lb; i++) {
            if (!equal(xa[i], xb[i]))
                return order3(xa[i], xb[i], op);
        }
        return la < lb ? -1 : la > lb;
    }
    }
bad:
    star_error("%s %s %s not implemented", type_name(a), cmp_op_str(op), type_name(b));
    return 0;
}

int compare(V a, V b, int op)
{
    int c;
    switch (op) {
    case T_EQL: return equal(a, b);
    case T_NEQ: return !equal(a, b);
    }
    c = order3(a, b, op);
    switch (op) {
    case T_LT: return c < 0;
    case T_GT: return c > 0;
    case T_LE: return c <= 0;
    case T_GE: return c >= 0;
    }
    return 0;
}

int cmp3(V a, V b)
{
    return order3(a, b, T_LT);
}

/* ---------------------------------------------------------------- repr -- */

static void quote_to(Buf *b, Str *s)
{
    int i = 0;
    buf_putc(b, '"');
    while (i < s->len) {
        unsigned char c = (unsigned char)s->s[i];
        if (c >= 0x80) {
            int cp, n = utf8_decode((const unsigned char *)s->s + i, s->len - i, &cp);
            if (n > 0) {
                buf_put(b, s->s + i, n);
                i += n;
                continue;
            }
            buf_printf(b, "\\x%02x", c);
            i++;
            continue;
        }
        switch (c) {
        case '\a': buf_puts(b, "\\a"); break;
        case '\b': buf_puts(b, "\\b"); break;
        case '\f': buf_puts(b, "\\f"); break;
        case '\n': buf_puts(b, "\\n"); break;
        case '\r': buf_puts(b, "\\r"); break;
        case '\t': buf_puts(b, "\\t"); break;
        case '\v': buf_puts(b, "\\v"); break;
        case '\\': buf_puts(b, "\\\\"); break;
        case '"': buf_puts(b, "\\\""); break;
        default:
            if (c < 0x20 || c == 0x7f)
                buf_printf(b, "\\x%02x", c);
            else
                buf_putc(b, c);
        }
        i++;
    }
    buf_putc(b, '"');
}

/* containers currently being printed, for cycle detection */
static V repr_stack[256];
int repr_depth;

void repr_to(Buf *b, V v)
{
    int i;
    if (TYPE(v) == T_LIST || TYPE(v) == T_DICT) {
        for (i = 0; i < repr_depth; i++) {
            if (repr_stack[i] == v) {
                buf_puts(b, TYPE(v) == T_LIST ? "[...]" : "{...}");
                return;
            }
        }
    }
    if (repr_depth >= 256) {
        repr_depth = 0;
        star_error("maximum recursion depth exceeded in repr");
    }
    repr_stack[repr_depth++] = v;
    switch (TYPE(v)) {
    case T_NONE: buf_puts(b, "None"); break;
    case T_BOOL: buf_puts(b, ((Bool *)v)->v ? "True" : "False"); break;
    case T_INT: buf_printf(b, "%lld", (long long)AS_INT(v)); break;
    case T_STRING: quote_to(b, AS_STR(v)); break;
    case T_LIST: {
        List *l = AS_LIST(v);
        buf_putc(b, '[');
        for (i = 0; i < l->len; i++) {
            if (i)
                buf_puts(b, ", ");
            repr_to(b, l->items[i]);
        }
        buf_putc(b, ']');
        break;
    }
    case T_TUPLE: {
        Tuple *t = AS_TUPLE(v);
        buf_putc(b, '(');
        for (i = 0; i < t->len; i++) {
            if (i)
                buf_puts(b, ", ");
            repr_to(b, t->items[i]);
        }
        if (t->len == 1)
            buf_putc(b, ',');
        buf_putc(b, ')');
        break;
    }
    case T_DICT: {
        Dict *d = AS_DICT(v);
        int first = 1;
        buf_putc(b, '{');
        for (i = 0; i < d->nents; i++) {
            if (!d->ents[i].key)
                continue;
            if (!first)
                buf_puts(b, ", ");
            first = 0;
            repr_to(b, d->ents[i].key);
            buf_puts(b, ": ");
            repr_to(b, d->ents[i].val);
        }
        buf_putc(b, '}');
        break;
    }
    case T_RANGE: {
        Range *r = (Range *)v;
        if (r->step != 1)
            buf_printf(b, "range(%lld, %lld, %lld)", (long long)r->start, (long long)r->stop, (long long)r->step);
        else if (r->start != 0)
            buf_printf(b, "range(%lld, %lld)", (long long)r->start, (long long)r->stop);
        else
            buf_printf(b, "range(%lld)", (long long)r->stop);
        break;
    }
    case T_FUNCTION:
        buf_printf(b, "<function %s>", ((Function *)v)->info->name->s);
        break;
    case T_BUILTIN: {
        Builtin *bi = (Builtin *)v;
        if (bi->recv)
            buf_printf(b, "<built-in method %s of %s value>", bi->name, type_name(bi->recv));
        else
            buf_printf(b, "<built-in function %s>", bi->name);
        break;
    }
    case T_STRUCT: {
        Struct *s = (Struct *)v;
        if (s->label && strcmp(s->ctor, "module") == 0) {
            buf_puts(b, "<module ");
            repr_to(b, s->label);
            buf_putc(b, '>');
            break;
        }
        buf_printf(b, "%s(", s->ctor);
        for (i = 0; i < s->n; i++) {
            if (i)
                buf_puts(b, ", ");
            buf_printf(b, "%s = ", s->names[i]->s);
            repr_to(b, s->vals[i]);
        }
        buf_putc(b, ')');
        break;
    }
    case T_MODULE:
        buf_printf(b, "<module %s>", ((Module *)v)->name);
        break;
    case T_STRVIEW: {
        StrView *w = (StrView *)v;
        quote_to(b, w->s);
        buf_printf(b, ".%s%s()", w->codepoints ? "codepoint" : "elem", w->ords ? "_ords" : "s");
        break;
    }
    default:
        buf_puts(b, "<?>");
    }
    repr_depth--;
}

void str_to(Buf *b, V v)
{
    if (TYPE(v) == T_STRING)
        buf_put(b, AS_STR(v)->s, AS_STR(v)->len);
    else
        repr_to(b, v);
}

V repr_value(V v)
{
    Buf b;
    buf_init(&b);
    repr_to(&b, v);
    return mk_str(b.p ? b.p : "", b.len);
}

V str_value(V v)
{
    Buf b;
    if (TYPE(v) == T_STRING)
        return v;
    buf_init(&b);
    repr_to(&b, v);
    return mk_str(b.p ? b.p : "", b.len);
}

/* --------------------------------------------------------------- lists -- */

void list_check_mutable(V l, const char *what)
{
    List *x = AS_LIST(l);
    if (x->frozen)
        star_error("cannot %s frozen list", what);
    if (x->itercount > 0)
        star_error("cannot %s list during iteration", what);
}

void list_append(V l, V v)
{
    List *x = AS_LIST(l);
    if (x->len == x->cap) {
        int nc = x->cap ? x->cap * 2 : 4;
        x->items = arena_grow(x->items, sizeof(V) * x->cap, sizeof(V) * nc);
        x->cap = nc;
    }
    x->items[x->len++] = v;
}

/* ---------------------------------------------------------------- dicts -- */

void dict_check_mutable(V d, const char *what)
{
    Dict *x = AS_DICT(d);
    if (x->frozen)
        star_error("cannot %s frozen hash table", what);
    if (x->itercount > 0)
        star_error("cannot %s hash table during iteration", what);
}

static void dict_reindex(Dict *d, int mincap)
{
    int cap = 8, i, j;
    /* compact deleted entries */
    for (i = j = 0; i < d->nents; i++)
        if (d->ents[i].key)
            d->ents[j++] = d->ents[i];
    d->nents = j;
    while (cap < mincap * 2)
        cap *= 2;
    d->index = arena_alloc(sizeof(int) * cap);
    d->indexcap = cap;
    for (i = 0; i < d->nents; i++) {
        int k = d->ents[i].hash & (cap - 1);
        while (d->index[k])
            k = (k + 1) & (cap - 1);
        d->index[k] = i + 1;
    }
}

static int dict_find(Dict *d, V key, uint32_t h)
{
    int k;
    if (!d->indexcap)
        return -1;
    k = h & (d->indexcap - 1);
    while (d->index[k]) {
        DEntry *e = &d->ents[d->index[k] - 1];
        if (e->key && e->hash == h && equal(e->key, key))
            return d->index[k] - 1;
        k = (k + 1) & (d->indexcap - 1);
    }
    return -1;
}

V dict_get(V dv, V key)
{
    Dict *d = AS_DICT(dv);
    uint32_t h = hash_value(key);
    int i = dict_find(d, key, h);
    return i < 0 ? NULL : d->ents[i].val;
}

void dict_set(V dv, V key, V val)
{
    Dict *d = AS_DICT(dv);
    uint32_t h = hash_value(key);
    int i = dict_find(d, key, h);
    if (i >= 0) {
        d->ents[i].val = val;
        return;
    }
    if (d->nents == d->entcap) {
        int nc = d->entcap ? d->entcap * 2 : 4;
        d->ents = arena_grow(d->ents, sizeof(DEntry) * d->entcap, sizeof(DEntry) * nc);
        d->entcap = nc;
    }
    d->ents[d->nents].key = key;
    d->ents[d->nents].val = val;
    d->ents[d->nents].hash = h;
    d->nents++;
    d->count++;
    if (d->nents * 2 > d->indexcap)
        dict_reindex(d, d->nents);
    else {
        int k = h & (d->indexcap - 1);
        while (d->index[k])
            k = (k + 1) & (d->indexcap - 1);
        d->index[k] = d->nents;
    }
}

int dict_del(V dv, V key, V *out)
{
    Dict *d = AS_DICT(dv);
    uint32_t h = hash_value(key);
    int i = dict_find(d, key, h);
    if (i < 0)
        return 0;
    if (out)
        *out = d->ents[i].val;
    d->ents[i].key = NULL;
    d->ents[i].val = NULL;
    d->count--;
    /* the index slot keeps pointing at the dead entry; lookups skip it */
    if (d->count * 4 < d->nents && d->nents > 8)
        dict_reindex(d, d->count);
    return 1;
}

/* ------------------------------------------------------------- freezing -- */

void freeze_value(V v)
{
    int i;
    switch (TYPE(v)) {
    case T_LIST: {
        List *l = AS_LIST(v);
        if (l->frozen)
            return;
        l->frozen = 1;
        for (i = 0; i < l->len; i++)
            freeze_value(l->items[i]);
        return;
    }
    case T_TUPLE:
        for (i = 0; i < AS_TUPLE(v)->len; i++)
            freeze_value(AS_TUPLE(v)->items[i]);
        return;
    case T_DICT: {
        Dict *d = AS_DICT(v);
        if (d->frozen)
            return;
        d->frozen = 1;
        for (i = 0; i < d->nents; i++) {
            if (!d->ents[i].key)
                continue;
            freeze_value(d->ents[i].key);
            freeze_value(d->ents[i].val);
        }
        return;
    }
    case T_STRUCT: {
        Struct *s = (Struct *)v;
        if (s->frozen)
            return;
        s->frozen = 1;
        for (i = 0; i < s->n; i++)
            freeze_value(s->vals[i]);
        return;
    }
    case T_FUNCTION: {
        Function *f = (Function *)v;
        for (i = 0; i < f->info->nparams; i++)
            if (f->defaults && f->defaults[i])
                freeze_value(f->defaults[i]);
        for (i = 0; i < f->info->nfree; i++)
            if (f->free[i]->v)
                freeze_value(f->free[i]->v);
        return;
    }
    }
}

/* ------------------------------------------------------------ iteration -- */

V strview_list(V v);   /* strmethods.c */

int iterable(V v)
{
    switch (TYPE(v)) {
    case T_LIST: case T_TUPLE: case T_DICT: case T_RANGE: case T_STRVIEW:
        return 1;
    }
    return 0;
}

/* Active list/dict iterations, so that an error unwinding past a loop (to a
 * catch point) can release the containers' iteration locks. */
static Iter *iter_stack[4096];
int iter_sp;

void iter_unwind(int sp)
{
    while (iter_sp > sp)
        iter_done(iter_stack[iter_sp - 1]);
}

void iter_start(Iter *it, V v)
{
    it->src = v;
    it->i = 0;
    switch (TYPE(v)) {
    case T_LIST:
    case T_DICT:
        if (iter_sp == 4096)
            star_error("too many nested iterations");
        if (TYPE(v) == T_LIST)
            AS_LIST(v)->itercount++;
        else
            AS_DICT(v)->itercount++;
        iter_stack[iter_sp++] = it;
        return;
    case T_TUPLE:
        return;
    case T_RANGE:
        it->r = ((Range *)v)->start;
        return;
    case T_STRVIEW:
        it->list = strview_list(v);
        return;
    }
    if (TYPE(v) == T_STRING)
        star_error("string value is not iterable");
    star_error("%s value is not iterable", type_name(v));
}

V iter_next(Iter *it)
{
    V v = it->src;
    switch (TYPE(v)) {
    case T_LIST:
        if (it->i < AS_LIST(v)->len)
            return AS_LIST(v)->items[it->i++];
        return NULL;
    case T_TUPLE:
        if (it->i < AS_TUPLE(v)->len)
            return AS_TUPLE(v)->items[it->i++];
        return NULL;
    case T_STRVIEW:
        if (it->i < AS_LIST(it->list)->len)
            return AS_LIST(it->list)->items[it->i++];
        return NULL;
    case T_DICT: {
        Dict *d = AS_DICT(v);
        while (it->i < d->nents && !d->ents[it->i].key)
            it->i++;
        if (it->i < d->nents)
            return d->ents[it->i++].key;
        return NULL;
    }
    case T_RANGE: {
        Range *r = (Range *)v;
        int64_t x = it->r;
        if (r->step > 0 ? x >= r->stop : x <= r->stop)
            return NULL;
        it->r = x + r->step;
        /* guard against wrap-around at the int64 edges */
        if ((r->step > 0 && it->r < x) || (r->step < 0 && it->r > x))
            it->r = r->stop;
        return mk_int(x);
    }
    }
    return NULL;
}

void iter_done(Iter *it)
{
    if (!it->src)
        return;
    if (TYPE(it->src) == T_LIST || TYPE(it->src) == T_DICT) {
        if (TYPE(it->src) == T_LIST)
            AS_LIST(it->src)->itercount--;
        else
            AS_DICT(it->src)->itercount--;
        /* iterations nest, so this is normally the top of the stack */
        if (iter_sp > 0 && iter_stack[iter_sp - 1] == it)
            iter_sp--;
    }
    it->src = NULL;
}

V to_list(V v)
{
    V out;
    Iter it;
    V x;
    int n = seq_len(v);
    out = mk_list(n > 0 ? n : 4);
    if (TYPE(v) == T_LIST) {
        memcpy(AS_LIST(out)->items, AS_LIST(v)->items, sizeof(V) * AS_LIST(v)->len);
        AS_LIST(out)->len = AS_LIST(v)->len;
        return out;
    }
    iter_start(&it, v);
    while ((x = iter_next(&it)) != NULL)
        list_append(out, x);
    iter_done(&it);
    return out;
}
