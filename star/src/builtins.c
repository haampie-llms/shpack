/* SPDX-License-Identifier: MIT
 * builtins.c -- the universe (predeclared in every module) and the list and
 * dict methods. Error messages follow starlark-go's where tests rely on them. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "star.h"

FILE *print_stream;

/* ------------------------------------------------------------- universe -- */

static V b_abs(Args *a)
{
    V x;
    unpack_positional(a, 1, 1, &x);
    if (TYPE(x) != T_INT)
        star_error("abs: got %s, want int", type_name(x));
    if (AS_INT(x) == INT64_MIN)
        star_error("abs: int overflow (ints are 64-bit)");
    return mk_int(AS_INT(x) < 0 ? -AS_INT(x) : AS_INT(x));
}

static V b_any_all(Args *a, int want)
{
    V x, e;
    Iter it;
    unpack_positional(a, 1, 1, &x);
    if (!iterable(x))
        star_error("%s: got %s, want iterable", a->name, type_name(x));
    iter_start(&it, x);
    while ((e = iter_next(&it)) != NULL) {
        if (truth(e) == want) {
            iter_done(&it);
            return mk_bool(want);
        }
    }
    iter_done(&it);
    return mk_bool(!want);
}
static V b_any(Args *a) { return b_any_all(a, 1); }
static V b_all(Args *a) { return b_any_all(a, 0); }

static V b_bool(Args *a)
{
    V x = NULL;
    unpack_positional(a, 0, 1, &x);
    return mk_bool(x ? truth(x) : 0);
}

static V b_chr(Args *a)
{
    V x;
    int64_t cp;
    char enc[4];
    unpack_positional(a, 1, 1, &x);
    cp = want_int(x, "chr");
    if (cp < 0)
        star_error("chr: Unicode code point %lld out of range (<0)", (long long)cp);
    if (cp > 0x10FFFF)
        star_error("chr: Unicode code point U+%llX out of range (>0x10FFFF)", (long long)cp);
    return mk_str(enc, utf8_encode(enc, (int)cp));
}

static V b_ord(Args *a)
{
    V x;
    Str *s;
    int cp, n;
    unpack_positional(a, 1, 1, &x);
    s = want_str(x, "ord");
    {
        /* an invalid byte decodes as U+FFFD, as in Go */
        int count = 0, i = 0;
        while (i < s->len) {
            int c, k = utf8_decode((unsigned char *)s->s + i, s->len - i, &c);
            if (k <= 0) {
                k = 1;
                c = 0xFFFD;
            }
            if (count == 0)
                cp = c;
            i += k;
            count++;
        }
        if (count != 1)
            star_error("ord: string encodes %d Unicode code points, want 1", count);
    }
    (void)n;
    return mk_int(cp);
}

static void dict_update(V d, Args *a, const char *name)
{
    int i;
    if (a->npos > 1)
        star_error("%s: got %d arguments, want at most 1", name, a->npos);
    if (a->npos == 1) {
        V src = a->pos[0];
        if (TYPE(src) == T_DICT) {
            Dict *s = AS_DICT(src);
            for (i = 0; i < s->nents; i++)
                if (s->ents[i].key)
                    dict_set(d, s->ents[i].key, s->ents[i].val);
        } else {
            Iter it;
            V e;
            int k = 0;
            if (!iterable(src))
                star_error("%s: got %s, want iterable", name, type_name(src));
            iter_start(&it, src);
            while ((e = iter_next(&it)) != NULL) {
                V l;
                if (!iterable(e))
                    star_error("%s: element #%d is not iterable (%s)", name, k, type_name(e));
                l = to_list(e);
                if (AS_LIST(l)->len != 2)
                    star_error("%s: element #%d has length %d, want 2", name, k, AS_LIST(l)->len);
                dict_set(d, AS_LIST(l)->items[0], AS_LIST(l)->items[1]);
                k++;
            }
            iter_done(&it);
        }
    }
    for (i = 0; i < a->nkw; i++)
        dict_set(d, (V)a->kwnames[i], a->kwvals[i]);
}

static V b_dict(Args *a)
{
    V d = mk_dict();
    int i, j;
    for (i = 0; i < a->nkw; i++)
        for (j = 0; j < i; j++)
            if (a->kwnames[i] == a->kwnames[j])
                star_error("dict: duplicate keyword arg: \"%s\"", a->kwnames[i]->s);
    dict_update(d, a, "dict");
    return d;
}

static int str_less(const void *x, const void *y)
{
    Str *a = *(Str **)x, *b = *(Str **)y;
    int n = a->len < b->len ? a->len : b->len;
    int c = memcmp(a->s, b->s, n);
    return c ? c : a->len - b->len;
}

static V b_dir(Args *a)
{
    V x, l;
    unpack_positional(a, 1, 1, &x);
    l = mk_list(0);
    if (TYPE(x) == T_STRUCT) {
        Struct *s = (Struct *)x;
        int i;
        for (i = 0; i < s->n; i++)
            list_append(l, (V)s->names[i]);
    }
    method_names(x, l);
    qsort(AS_LIST(l)->items, AS_LIST(l)->len, sizeof(V), str_less);
    return l;
}

static V b_enumerate(Args *a)
{
    V x, start = NULL, l, e;
    int64_t i = 0;
    Iter it;
    unpack_args(a, "iterable", &x, "start?", &start, NULL);
    if (start)
        i = want_int(start, "enumerate");
    if (!iterable(x))
        star_error("enumerate: got %s, want iterable", type_name(x));
    l = mk_list(0);
    iter_start(&it, x);
    while ((e = iter_next(&it)) != NULL) {
        V t = mk_tuple(2);
        AS_TUPLE(t)->items[0] = mk_int(i++);
        AS_TUPLE(t)->items[1] = e;
        list_append(l, t);
    }
    iter_done(&it);
    return l;
}

static V b_fail(Args *a)
{
    Buf b;
    const char *sep = " ";
    int i;
    for (i = 0; i < a->nkw; i++) {
        if (str_eq(a->kwnames[i], "sep") && TYPE(a->kwvals[i]) == T_STRING)
            sep = AS_STR(a->kwvals[i])->s;
        else
            star_error("fail: unexpected keyword argument %s", a->kwnames[i]->s);
    }
    buf_init(&b);
    buf_puts(&b, "fail: ");
    for (i = 0; i < a->npos; i++) {
        if (i)
            buf_puts(&b, sep);
        str_to(&b, a->pos[i]);
    }
    star_error("%s", buf_cstr(&b));
    return NULL;
}

static V b_float(Args *a)
{
    (void)a;
    star_error("float: floating-point numbers are not supported in this dialect");
    return NULL;
}

static V b_getattr(Args *a)
{
    V x, name, def = NULL, v;
    unpack_positional(a, 2, 3, &x, &name, &def);
    v = get_attr(x, intern_n(want_str(name, "getattr")->s, AS_STR(name)->len), def == NULL);
    return v ? v : def;
}

static V b_hasattr(Args *a)
{
    V x, name;
    unpack_positional(a, 2, 2, &x, &name);
    return mk_bool(get_attr(x, intern_n(want_str(name, "hasattr")->s, AS_STR(name)->len), 0) != NULL);
}

static V b_hash(Args *a)
{
    V x;
    Str *s;
    int32_t h = 0;
    int i;
    unpack_positional(a, 1, 1, &x);
    if (TYPE(x) != T_STRING)
        star_error("hash: got %s, want string", type_name(x));
    s = AS_STR(x);
    /* Java's String.hashCode, over UTF-16 code units, as starlark-go does
     * (invalid UTF-8 bytes count as U+FFFD) */
    for (i = 0; i < s->len;) {
        int cp, n = utf8_decode((unsigned char *)s->s + i, s->len - i, &cp);
        if (n <= 0) {
            n = 1;
            cp = 0xFFFD;
        }
        i += n;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            h = (int32_t)((uint32_t)h * 31u + (uint32_t)(0xD800 + (cp >> 10)));
            h = (int32_t)((uint32_t)h * 31u + (uint32_t)(0xDC00 + (cp & 0x3FF)));
        } else {
            h = (int32_t)((uint32_t)h * 31u + (uint32_t)cp);
        }
    }
    return mk_int(h);
}

static int digit_val(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return 99;
}

/* starlark-go's parseInt: sign, optional base prefix, digits. Returns 0 on
 * failure. */
static int parse_int(const char *s, int len, int base, int64_t *out)
{
    int neg = 0, prefix = 0, i;
    uint64_t v = 0;
    if (len && s[0] == '+') {
        s++;
        len--;
    } else if (len && s[0] == '-') {
        neg = 1;
        s++;
        len--;
    }
    if (len > 1 && s[0] == '0') {
        if (len > 2) {
            switch (s[1]) {
            case 'o': case 'O': prefix = 8; break;
            case 'x': case 'X': prefix = 16; break;
            case 'b': case 'B': prefix = 2; break;
            }
        }
        if (prefix == 0 && base == 0) {
            for (i = 1; i < len; i++)
                if (s[i] != '0')
                    return 0;
            *out = 0;
            return 1;
        }
    }
    if (prefix) {
        if (base == 0)
            base = prefix;
        else if (base != prefix)
            prefix = 0;     /* e.g. int("0b1", 16): the 'b' is a digit */
        if (prefix) {
            s += 2;
            len -= 2;
        }
    }
    if (base == 0)
        base = 10;
    if (len == 0)
        return 0;
    if (s[0] == '+' || s[0] == '-')
        return 0;
    for (i = 0; i < len; i++) {
        int d = digit_val((unsigned char)s[i]);
        if (d >= base)
            return 0;
        if (v > (UINT64_MAX - d) / base)
            return -1;
        v = v * base + d;
    }
    if (neg) {
        if (v > (uint64_t)INT64_MAX + 1)
            return -1;
        *out = (int64_t)(0 - v);
    } else {
        if (v > (uint64_t)INT64_MAX)
            return -1;
        *out = (int64_t)v;
    }
    return 1;
}

static V b_int(Args *a)
{
    V x = NULL, base = NULL;
    unpack_args(a, "x", &x, "base?", &base, NULL);
    if (TYPE(x) == T_STRING) {
        int64_t b = 10, v;
        int r;
        if (base) {
            b = want_int(base, "int");
            if (b != 0 && (b < 2 || b > 36))
                star_error("int: base must be an integer >= 2 && <= 36");
        }
        r = parse_int(AS_STR(x)->s, AS_STR(x)->len, (int)b, &v);
        if (r < 0)
            star_error("int: literal %s out of range (ints are 64-bit)", AS_STR(x)->s);
        if (r == 0) {
            Buf q;
            buf_init(&q);
            repr_to(&q, x);
            star_error("int: invalid literal with base %d: %s", (int)b, AS_STR(x)->s);
        }
        return mk_int(v);
    }
    if (base)
        star_error("int: can't convert non-string with explicit base");
    if (TYPE(x) == T_BOOL)
        return mk_int(truth(x));
    if (TYPE(x) == T_INT)
        return x;
    star_error("int: got %s, want int or string", type_name(x));
    return NULL;
}

static V b_len(Args *a)
{
    V x;
    int n;
    unpack_positional(a, 1, 1, &x);
    n = seq_len(x);
    if (n < 0)
        star_error("len: value of type %s has no len", type_name(x));
    return mk_int(n);
}

static V b_list(Args *a)
{
    V x = NULL;
    unpack_positional(a, 0, 1, &x);
    if (!x)
        return mk_list(0);
    if (!iterable(x))
        star_error("list: for parameter 1: got %s, want iterable", type_name(x));
    return to_list(x);
}

static V b_minmax(Args *a, int want_max)
{
    V key = NULL, seq, best = NULL, bestk = NULL, e;
    Iter it;
    int i;
    for (i = 0; i < a->nkw; i++) {
        if (str_eq(a->kwnames[i], "key"))
            key = a->kwvals[i];
        else {
            V c = mk_list(1);
            list_append(c, (V)intern("key"));
            if (did_you_mean(a->kwnames[i]->s, c))
                star_error("%s: unexpected keyword argument %s (did you mean key?)", a->name, a->kwnames[i]->s);
            star_error("%s: unexpected keyword argument %s", a->name, a->kwnames[i]->s);
        }
    }
    if (key == None)
        key = NULL;
    if (a->npos == 0)
        star_error("%s requires at least one positional argument", a->name);
    if (a->npos == 1) {
        seq = a->pos[0];
        if (!iterable(seq))
            star_error("%s: %s value is not iterable", a->name, type_name(seq));
    } else {
        seq = mk_tuple(a->npos);
        memcpy(AS_TUPLE(seq)->items, a->pos, sizeof(V) * a->npos);
    }
    iter_start(&it, seq);
    while ((e = iter_next(&it)) != NULL) {
        V k = key ? call_simple(key, 1, &e) : e;
        if (!best) {
            best = e;
            bestk = k;
        } else if (want_max ? compare(k, bestk, T_GT) : compare(k, bestk, T_LT)) {
            best = e;
            bestk = k;
        }
    }
    iter_done(&it);
    if (!best)
        star_error("%s: argument is an empty sequence", a->name);
    return best;
}
static V b_max(Args *a) { return b_minmax(a, 1); }
static V b_min(Args *a) { return b_minmax(a, 0); }

static V b_print(Args *a)
{
    Buf b;
    const char *sep = " ";
    int i;
    for (i = 0; i < a->nkw; i++) {
        if (str_eq(a->kwnames[i], "sep") && TYPE(a->kwvals[i]) == T_STRING)
            sep = AS_STR(a->kwvals[i])->s;
        else
            star_error("print: unexpected keyword argument %s", a->kwnames[i]->s);
    }
    buf_init(&b);
    for (i = 0; i < a->npos; i++) {
        if (i)
            buf_puts(&b, sep);
        str_to(&b, a->pos[i]);
    }
    buf_putc(&b, '\n');
    fwrite(b.p, 1, b.len, print_stream ? print_stream : stderr);
    return None;
}

static V b_range(Args *a)
{
    V x = NULL, y = NULL, z = NULL;
    int64_t start = 0, stop, step = 1;
    unpack_positional(a, 1, 3, &x, &y, &z);
    if (y) {
        start = want_int(x, "range");
        stop = want_int(y, "range");
    } else {
        stop = want_int(x, "range");
    }
    if (z) {
        step = want_int(z, "range");
        if (step == 0)
            star_error("range: step argument must not be zero");
    }
    return mk_range(start, stop, step);
}

static V b_repr(Args *a)
{
    V x;
    unpack_positional(a, 1, 1, &x);
    return repr_value(x);
}

static V b_reversed(Args *a)
{
    V x, l;
    int i, n;
    unpack_positional(a, 1, 1, &x);
    if (!iterable(x))
        star_error("reversed: for parameter 1: got %s, want iterable", type_name(x));
    l = to_list(x);
    n = AS_LIST(l)->len;
    for (i = 0; i < n / 2; i++) {
        V t = AS_LIST(l)->items[i];
        AS_LIST(l)->items[i] = AS_LIST(l)->items[n - 1 - i];
        AS_LIST(l)->items[n - 1 - i] = t;
    }
    return l;
}

/* stable merge sort on parallel key/value arrays */
static void msort(V *keys, V *vals, V *tk, V *tv, int n, int reverse)
{
    int mid, i, j, k;
    if (n < 2)
        return;
    mid = n / 2;
    msort(keys, vals, tk, tv, mid, reverse);
    msort(keys + mid, vals + mid, tk, tv, n - mid, reverse);
    i = 0;
    j = mid;
    k = 0;
    while (i < mid && j < n) {
        int c = cmp3(keys[j], keys[i]);
        if (reverse ? c > 0 : c < 0) {
            tk[k] = keys[j];
            tv[k++] = vals[j++];
        } else {
            tk[k] = keys[i];
            tv[k++] = vals[i++];
        }
    }
    while (i < mid) {
        tk[k] = keys[i];
        tv[k++] = vals[i++];
    }
    while (j < n) {
        tk[k] = keys[j];
        tv[k++] = vals[j++];
    }
    memcpy(keys, tk, sizeof(V) * n);
    memcpy(vals, tv, sizeof(V) * n);
}

static V b_sorted(Args *a)
{
    V x, key = NULL, rev = NULL, l, keys;
    int i, n;
    unpack_args(a, "iterable", &x, "key?", &key, "reverse?", &rev, NULL);
    if (!iterable(x))
        star_error("sorted: for parameter iterable: got %s, want iterable", type_name(x));
    if (key && TYPE(key) != T_FUNCTION && TYPE(key) != T_BUILTIN)
        star_error("sorted: for parameter key: got %s, want callable", type_name(key));
    l = to_list(x);
    n = AS_LIST(l)->len;
    keys = mk_list(n);
    for (i = 0; i < n; i++)
        AS_LIST(keys)->items[i] = key ? call_simple(key, 1, &AS_LIST(l)->items[i])
                                                     : AS_LIST(l)->items[i];
    AS_LIST(keys)->len = n;
    msort(AS_LIST(keys)->items, AS_LIST(l)->items, arena_alloc(sizeof(V) * (n + 1)),
          arena_alloc(sizeof(V) * (n + 1)), n, rev ? truth(rev) : 0);
    return l;
}

static V b_str(Args *a)
{
    V x;
    unpack_positional(a, 1, 1, &x);
    return str_value(x);
}

static V b_tuple(Args *a)
{
    V x = NULL, l, t;
    unpack_positional(a, 0, 1, &x);
    if (!x)
        return mk_tuple(0);
    if (TYPE(x) == T_TUPLE)
        return x;
    if (!iterable(x))
        star_error("tuple: for parameter 1: got %s, want iterable", type_name(x));
    l = to_list(x);
    t = mk_tuple(AS_LIST(l)->len);
    memcpy(AS_TUPLE(t)->items, AS_LIST(l)->items, sizeof(V) * AS_LIST(l)->len);
    return t;
}

static V b_type(Args *a)
{
    V x;
    unpack_positional(a, 1, 1, &x);
    return (V)intern(type_name(x));
}

static V b_zip(Args *a)
{
    V out, *lists;
    int i, j, n = -1;
    no_kwargs(a);
    lists = arena_alloc(sizeof(V) * (a->npos + 1));
    for (i = 0; i < a->npos; i++) {
        if (!iterable(a->pos[i]))
            star_error("zip: argument #%d is not iterable: %s", i + 1, type_name(a->pos[i]));
        lists[i] = to_list(a->pos[i]);
        if (n < 0 || AS_LIST(lists[i])->len < n)
            n = AS_LIST(lists[i])->len;
    }
    if (n < 0)
        n = 0;
    out = mk_list(n);
    for (j = 0; j < n; j++) {
        V t = mk_tuple(a->npos);
        for (i = 0; i < a->npos; i++)
            AS_TUPLE(t)->items[i] = AS_LIST(lists[i])->items[j];
        list_append(out, t);
    }
    return out;
}

static V b_struct(Args *a)
{
    int i, j;
    if (a->npos)
        star_error("struct: unexpected positional arguments");
    for (i = 0; i < a->nkw; i++)
        for (j = 0; j < i; j++)
            if (a->kwnames[i] == a->kwnames[j])
                star_error("struct: duplicate field %s", a->kwnames[i]->s);
    return mk_struct("struct", a->nkw, a->kwnames, a->kwvals);
}

/* ----------------------------------------------------------- list methods -- */

static V l_append(Args *a)
{
    V x;
    unpack_positional(a, 1, 1, &x);
    list_check_mutable(a->self, "append to");
    list_append(a->self, x);
    return None;
}

static V l_clear(Args *a)
{
    unpack_positional(a, 0, 0);
    list_check_mutable(a->self, "clear");
    AS_LIST(a->self)->len = 0;
    return None;
}

static V l_extend(Args *a)
{
    V x, items;
    int i;
    unpack_positional(a, 1, 1, &x);
    list_check_mutable(a->self, "extend");
    if (!iterable(x))
        star_error("extend: got %s, want iterable", type_name(x));
    items = to_list(x);
    for (i = 0; i < AS_LIST(items)->len; i++)
        list_append(a->self, AS_LIST(items)->items[i]);
    return None;
}

static int64_t clamp_index(V v, int64_t def, int len)
{
    int64_t i;
    if (!v || v == None)
        return def;
    i = want_int(v, "index");
    if (i < 0) {
        i += len;
        if (i < 0)
            i = 0;
    }
    if (i > len)
        i = len;
    return i;
}

static V l_index(Args *a)
{
    V x, lo = NULL, hi = NULL;
    List *l = AS_LIST(a->self);
    int64_t i, start, stop;
    unpack_positional(a, 1, 3, &x, &lo, &hi);
    start = clamp_index(lo, 0, l->len);
    stop = clamp_index(hi, l->len, l->len);
    for (i = start; i < stop; i++)
        if (equal(l->items[i], x))
            return mk_int(i);
    star_error("index: value not in list");
    return NULL;
}

static V l_insert(Args *a)
{
    V iv, x;
    List *l = AS_LIST(a->self);
    int64_t i;
    unpack_positional(a, 2, 2, &iv, &x);
    list_check_mutable(a->self, "insert into");
    i = want_int(iv, "insert");
    if (i < 0) {
        i += l->len;
        if (i < 0)
            i = 0;
    }
    if (i > l->len)
        i = l->len;
    list_append(a->self, None);
    memmove(l->items + i + 1, l->items + i, sizeof(V) * (l->len - 1 - i));
    l->items[i] = x;
    return None;
}

static V l_pop(Args *a)
{
    V iv = NULL, r;
    List *l = AS_LIST(a->self);
    int64_t i;
    unpack_positional(a, 0, 1, &iv);
    list_check_mutable(a->self, "pop from");
    i = iv ? want_int(iv, "pop") : -1;
    if (i < 0)
        i += l->len;
    if (i < 0 || i >= l->len) {
        if (l->len == 0)
            star_error("pop: index %lld out of range: empty list", (long long)(iv ? AS_INT(iv) : -1));
        star_error("pop: index %lld out of range [%d:%d]", (long long)(iv ? AS_INT(iv) : -1),
                   -l->len, l->len - 1);
    }
    r = l->items[i];
    memmove(l->items + i, l->items + i + 1, sizeof(V) * (l->len - i - 1));
    l->len--;
    return r;
}

static V l_remove(Args *a)
{
    V x;
    List *l = AS_LIST(a->self);
    int i;
    unpack_positional(a, 1, 1, &x);
    list_check_mutable(a->self, "remove from");
    for (i = 0; i < l->len; i++) {
        if (equal(l->items[i], x)) {
            memmove(l->items + i, l->items + i + 1, sizeof(V) * (l->len - i - 1));
            l->len--;
            return None;
        }
    }
    star_error("remove: element not found");
    return NULL;
}

/* ----------------------------------------------------------- dict methods -- */

static V d_clear(Args *a)
{
    Dict *d = AS_DICT(a->self);
    unpack_positional(a, 0, 0);
    dict_check_mutable(a->self, "clear");
    d->count = d->nents = 0;
    d->indexcap = 0;
    d->index = NULL;
    return None;
}

static V d_get(Args *a)
{
    V k, def = NULL, v;
    unpack_positional(a, 1, 2, &k, &def);
    v = dict_get(a->self, k);
    return v ? v : def ? def : None;
}

static V d_items(Args *a)
{
    Dict *d = AS_DICT(a->self);
    V l = mk_list(d->count);
    int i;
    unpack_positional(a, 0, 0);
    for (i = 0; i < d->nents; i++) {
        V t;
        if (!d->ents[i].key)
            continue;
        t = mk_tuple(2);
        AS_TUPLE(t)->items[0] = d->ents[i].key;
        AS_TUPLE(t)->items[1] = d->ents[i].val;
        list_append(l, t);
    }
    return l;
}

static V d_keys(Args *a)
{
    Dict *d = AS_DICT(a->self);
    V l = mk_list(d->count);
    int i;
    unpack_positional(a, 0, 0);
    for (i = 0; i < d->nents; i++)
        if (d->ents[i].key)
            list_append(l, d->ents[i].key);
    return l;
}

static V d_values(Args *a)
{
    Dict *d = AS_DICT(a->self);
    V l = mk_list(d->count);
    int i;
    unpack_positional(a, 0, 0);
    for (i = 0; i < d->nents; i++)
        if (d->ents[i].key)
            list_append(l, d->ents[i].val);
    return l;
}

static V d_pop(Args *a)
{
    V k, def = NULL, v;
    unpack_positional(a, 1, 2, &k, &def);
    dict_check_mutable(a->self, "delete from");
    if (dict_del(a->self, k, &v))
        return v;
    if (def)
        return def;
    {
        Buf b;
        buf_init(&b);
        repr_to(&b, k);
        star_error("pop: missing key %s", buf_cstr(&b));
    }
    return NULL;
}

static V d_popitem(Args *a)
{
    Dict *d = AS_DICT(a->self);
    int i;
    unpack_positional(a, 0, 0);
    dict_check_mutable(a->self, "delete from");
    for (i = 0; i < d->nents; i++) {
        if (d->ents[i].key) {
            V t = mk_tuple(2);
            AS_TUPLE(t)->items[0] = d->ents[i].key;
            AS_TUPLE(t)->items[1] = d->ents[i].val;
            dict_del(a->self, d->ents[i].key, NULL);
            return t;
        }
    }
    star_error("popitem: empty dict");
    return NULL;
}

static V d_setdefault(Args *a)
{
    V k, def = NULL, v;
    unpack_positional(a, 1, 2, &k, &def);
    v = dict_get(a->self, k);
    if (v)
        return v;
    dict_check_mutable(a->self, "insert into");
    dict_set(a->self, k, def ? def : None);
    return def ? def : None;
}

static V d_update(Args *a)
{
    dict_check_mutable(a->self, "insert into");
    dict_update(a->self, a, "update");
    return None;
}

/* ------------------------------------------------------------- dispatch -- */

typedef struct Method { const char *name; BuiltinFn fn; } Method;

static const Method list_methods[] = {
    {"append", l_append}, {"clear", l_clear}, {"extend", l_extend},
    {"index", l_index}, {"insert", l_insert}, {"pop", l_pop},
    {"remove", l_remove}, {NULL, NULL}
};

static const Method dict_methods[] = {
    {"clear", d_clear}, {"get", d_get}, {"items", d_items}, {"keys", d_keys},
    {"pop", d_pop}, {"popitem", d_popitem}, {"setdefault", d_setdefault},
    {"update", d_update}, {"values", d_values}, {NULL, NULL}
};

static V find_method(const Method *t, V recv, Str *name)
{
    int i;
    for (i = 0; t[i].name; i++)
        if (str_eq(name, t[i].name))
            return mk_builtin(t[i].name, t[i].fn, recv);
    return NULL;
}

V builtin_method(V recv, Str *name)
{
    switch (TYPE(recv)) {
    case T_LIST: return find_method(list_methods, recv, name);
    case T_DICT: return find_method(dict_methods, recv, name);
    case T_STRING: return string_method(recv, name);
    }
    return NULL;
}

void method_names(V recv, V list)
{
    const Method *t = NULL;
    int i;
    switch (TYPE(recv)) {
    case T_LIST: t = list_methods; break;
    case T_DICT: t = dict_methods; break;
    case T_STRING: string_methods(list); return;
    }
    if (t)
        for (i = 0; t[i].name; i++)
            list_append(list, (V)intern(t[i].name));
}

/* -------------------------------------------------------------- universe -- */

static const Method universe_fns[] = {
    {"abs", b_abs}, {"all", b_all}, {"any", b_any}, {"bool", b_bool},
    {"chr", b_chr}, {"dict", b_dict}, {"dir", b_dir}, {"enumerate", b_enumerate},
    {"fail", b_fail}, {"float", b_float}, {"getattr", b_getattr},
    {"hasattr", b_hasattr}, {"hash", b_hash}, {"int", b_int}, {"len", b_len},
    {"list", b_list}, {"max", b_max}, {"min", b_min}, {"ord", b_ord},
    {"print", b_print}, {"range", b_range}, {"repr", b_repr},
    {"reversed", b_reversed}, {"sorted", b_sorted}, {"str", b_str},
    {"struct", b_struct}, {"tuple", b_tuple}, {"type", b_type}, {"zip", b_zip},
    {NULL, NULL}
};

static V universe;

void universe_init(void)
{
    int i;
    universe = mk_dict();
    dict_set(universe, (V)intern("None"), None);
    dict_set(universe, (V)intern("True"), True);
    dict_set(universe, (V)intern("False"), False);
    for (i = 0; universe_fns[i].name; i++)
        dict_set(universe, (V)intern(universe_fns[i].name),
                 mk_builtin(universe_fns[i].name, universe_fns[i].fn, NULL));
}

V universe_lookup(Str *name)
{
    return dict_get(universe, (V)name);
}

int universe_has(Str *name)
{
    return dict_get(universe, (V)name) != NULL;
}
