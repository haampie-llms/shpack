/* SPDX-License-Identifier: MIT
 * strmethods.c -- string methods, str.format, the % operator, and UTF-8.
 * Strings are byte strings; the case/class predicates are ASCII-only, which
 * is all recipes need and keeps the behaviour identical across backends
 * for the ASCII subset. */

#include <stdio.h>
#include <string.h>
#include "star.h"

/* ------------------------------------------------------------------ utf8 -- */

int utf8_decode(const unsigned char *s, int n, int *cp)
{
    int c = s[0], need, i, v;
    if (c < 0x80) {
        *cp = c;
        return 1;
    }
    if (c >= 0xC2 && c <= 0xDF) { need = 1; v = c & 0x1F; }
    else if (c >= 0xE0 && c <= 0xEF) { need = 2; v = c & 0x0F; }
    else if (c >= 0xF0 && c <= 0xF4) { need = 3; v = c & 0x07; }
    else return 0;
    if (n < need + 1)
        return 0;
    for (i = 1; i <= need; i++) {
        if ((s[i] & 0xC0) != 0x80)
            return 0;
        v = (v << 6) | (s[i] & 0x3F);
    }
    if ((need == 2 && v < 0x800) || (need == 3 && (v < 0x10000 || v > 0x10FFFF)) ||
        (v >= 0xD800 && v < 0xE000))
        return 0;
    *cp = v;
    return need + 1;
}

int utf8_encode(char *out, int cp)
{
    if (cp < 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp < 0xE000))
        cp = 0xFFFD;
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

/* ---------------------------------------------------------------- helpers -- */

#define SELF AS_STR(a->self)

static int is_space(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'; }
static int is_upper(int c) { return c >= 'A' && c <= 'Z'; }
static int is_lower(int c) { return c >= 'a' && c <= 'z'; }
static int is_alpha(int c) { return is_upper(c) || is_lower(c); }
static int is_digit(int c) { return c >= '0' && c <= '9'; }
static int to_upper(int c) { return is_lower(c) ? c - 32 : c; }
static int to_lower(int c) { return is_upper(c) ? c + 32 : c; }

/* Case mapping and character classes are ASCII-only in this dialect. Rather
 * than silently disagree with backends that apply Unicode tables, non-ASCII
 * input is an error. */
static void ascii_only(Args *a)
{
    Str *s = AS_STR(a->self);
    int i;
    for (i = 0; i < s->len; i++)
        if ((unsigned char)s->s[i] >= 0x80)
            star_error("%s: non-ASCII strings are not supported by this dialect", a->name);
}

static V substr(Str *s, int from, int to)
{
    if (from == 0 && to == s->len)
        return (V)s;
    return mk_str(s->s + from, to - from);
}

/* resolve optional start/end arguments to a byte range, like s[start:end] */
static void span(Str *s, V lo, V hi, int *from, int *to)
{
    int64_t a = 0, b = s->len;
    if (lo && lo != None) {
        a = want_int(lo, "start");
        if (a < 0) {
            a += s->len;
            if (a < 0)
                a = 0;
        }
        if (a > s->len)
            a = s->len;
    }
    if (hi && hi != None) {
        b = want_int(hi, "end");
        if (b < 0) {
            b += s->len;
            if (b < 0)
                b = 0;
        }
        if (b > s->len)
            b = s->len;
    }
    *from = (int)a;
    *to = (int)(b < a ? a : b);
}

static int find_sub(const char *h, int hn, const char *n, int nn, int from_right)
{
    int i;
    if (nn > hn)
        return -1;
    if (!from_right) {
        for (i = 0; i + nn <= hn; i++)
            if (memcmp(h + i, n, nn) == 0)
                return i;
    } else {
        for (i = hn - nn; i >= 0; i--)
            if (memcmp(h + i, n, nn) == 0)
                return i;
    }
    return -1;
}

/* --------------------------------------------------------------- methods -- */

static V s_capitalize(Args *a)
{
    Str *s = SELF;
    Buf b;
    int i;
    unpack_positional(a, 0, 0);
    ascii_only(a);
    buf_init(&b);
    for (i = 0; i < s->len; i++)
        buf_putc(&b, i == 0 ? to_upper((unsigned char)s->s[i]) : to_lower((unsigned char)s->s[i]));
    return mk_str(b.p ? b.p : "", b.len);
}

static V s_count(Args *a)
{
    V sub, lo = NULL, hi = NULL;
    Str *s = SELF, *n;
    int from, to, count = 0, i;
    unpack_positional(a, 1, 3, &sub, &lo, &hi);
    n = want_str(sub, "count");
    span(s, lo, hi, &from, &to);
    if (n->len == 0)
        return mk_int(to - from + 1);
    for (i = from; i + n->len <= to;) {
        if (memcmp(s->s + i, n->s, n->len) == 0) {
            count++;
            i += n->len;
        } else {
            i++;
        }
    }
    return mk_int(count);
}

/* the elements of a string view, as a fresh list */
V strview_list(V v)
{
    StrView *w = (StrView *)v;
    Str *s = w->s;
    V l = mk_list(s->len);
    int i = 0;
    while (i < s->len) {
        int cp, n = 1;
        if (w->codepoints) {
            n = utf8_decode((unsigned char *)s->s + i, s->len - i, &cp);
            if (n == 0) {
                n = 1;
                cp = 0xFFFD;
            }
        } else {
            cp = (unsigned char)s->s[i];
        }
        if (w->ords)
            list_append(l, mk_int(cp));
        else if (w->codepoints && cp == 0xFFFD && n == 1) {
            char enc[4];
            list_append(l, mk_str(enc, utf8_encode(enc, cp)));
        } else
            list_append(l, mk_str(s->s + i, n));
        i += n;
    }
    return l;
}

static V elems_impl(Args *a, int ords, int codepoints)
{
    StrView *w = arena_alloc(sizeof(StrView));
    unpack_positional(a, 0, 0);
    w->type = T_STRVIEW;
    w->s = SELF;
    w->ords = ords;
    w->codepoints = codepoints;
    return (V)w;
}
static V s_elems(Args *a) { return elems_impl(a, 0, 0); }
static V s_elem_ords(Args *a) { return elems_impl(a, 1, 0); }
static V s_codepoints(Args *a) { return elems_impl(a, 0, 1); }
static V s_codepoint_ords(Args *a) { return elems_impl(a, 1, 1); }

static V affix(Args *a, int suffix)
{
    V x, lo = NULL, hi = NULL;
    Str *s = SELF;
    int from, to, i;
    unpack_positional(a, 1, 3, &x, &lo, &hi);
    span(s, lo, hi, &from, &to);
    if (TYPE(x) == T_TUPLE) {
        for (i = 0; i < AS_TUPLE(x)->len; i++) {
            Str *p;
            if (TYPE(AS_TUPLE(x)->items[i]) != T_STRING)
                star_error("%s: want string, got %s, for element %d", a->name,
                           type_name(AS_TUPLE(x)->items[i]), i);
            p = AS_STR(AS_TUPLE(x)->items[i]);
            if (p->len <= to - from &&
                memcmp(s->s + (suffix ? to - p->len : from), p->s, p->len) == 0)
                return True;
        }
        return False;
    }
    if (TYPE(x) != T_STRING)
        star_error("%s: got %s, want string or tuple of string", a->name, type_name(x));
    {
        Str *p = AS_STR(x);
        return mk_bool(p->len <= to - from &&
                       memcmp(s->s + (suffix ? to - p->len : from), p->s, p->len) == 0);
    }
}
static V s_startswith(Args *a) { return affix(a, 0); }
static V s_endswith(Args *a) { return affix(a, 1); }

static V find_impl(Args *a, int right, int must)
{
    V sub, lo = NULL, hi = NULL;
    Str *s = SELF, *n;
    int from, to, i;
    unpack_positional(a, 1, 3, &sub, &lo, &hi);
    n = want_str(sub, a->name);
    span(s, lo, hi, &from, &to);
    i = find_sub(s->s + from, to - from, n->s, n->len, right);
    if (i < 0) {
        if (must)
            star_error("%s: substring not found", a->name);
        return mk_int(-1);
    }
    return mk_int(from + i);
}
static V s_find(Args *a) { return find_impl(a, 0, 0); }
static V s_rfind(Args *a) { return find_impl(a, 1, 0); }
static V s_index(Args *a) { return find_impl(a, 0, 1); }
static V s_rindex(Args *a) { return find_impl(a, 1, 1); }

static V s_format(Args *a)
{
    return string_format(SELF, a);
}

static V pred(Args *a, int kind)
{
    Str *s = SELF;
    int i, cased = 0, ok = s->len > 0;
    unpack_positional(a, 0, 0);
    ascii_only(a);
    for (i = 0; i < s->len; i++) {
        int c = (unsigned char)s->s[i];
        switch (kind) {
        case 0: if (!is_alpha(c) && !is_digit(c)) ok = 0; break;   /* isalnum */
        case 1: if (!is_alpha(c)) ok = 0; break;                   /* isalpha */
        case 2: if (!is_digit(c)) ok = 0; break;                   /* isdigit */
        case 3: if (is_upper(c)) ok = 0; if (is_lower(c)) cased = 1; break; /* islower */
        case 4: if (!is_space(c)) ok = 0; break;                   /* isspace */
        case 5: if (is_lower(c)) ok = 0; if (is_upper(c)) cased = 1; break; /* isupper */
        }
    }
    if (kind == 3 || kind == 5)
        return mk_bool(ok && cased);
    return mk_bool(ok);
}
static V s_isalnum(Args *a) { return pred(a, 0); }
static V s_isalpha(Args *a) { return pred(a, 1); }
static V s_isdigit(Args *a) { return pred(a, 2); }
static V s_islower(Args *a) { return pred(a, 3); }
static V s_isspace(Args *a) { return pred(a, 4); }
static V s_isupper(Args *a) { return pred(a, 5); }

static V s_istitle(Args *a)
{
    Str *s = SELF;
    int i, prev_cased = 0, cased = 0;
    unpack_positional(a, 0, 0);
    ascii_only(a);
    for (i = 0; i < s->len; i++) {
        int c = (unsigned char)s->s[i];
        if (is_upper(c)) {
            if (prev_cased)
                return False;
            prev_cased = cased = 1;
        } else if (is_lower(c)) {
            if (!prev_cased)
                return False;
            prev_cased = cased = 1;
        } else {
            prev_cased = 0;
        }
    }
    return mk_bool(cased);
}

static V s_join(Args *a)
{
    V it, e;
    Str *s = SELF;
    Iter iter;
    Buf b;
    int first = 1;
    unpack_positional(a, 1, 1, &it);
    if (!iterable(it))
        star_error("join: got %s, want iterable", type_name(it));
    buf_init(&b);
    iter_start(&iter, it);
    while ((e = iter_next(&iter)) != NULL) {
        if (TYPE(e) != T_STRING)
            star_error("join: in %s, want string, got %s", type_name(it), type_name(e));
        if (!first)
            buf_put(&b, s->s, s->len);
        first = 0;
        buf_put(&b, AS_STR(e)->s, AS_STR(e)->len);
    }
    iter_done(&iter);
    return mk_str(b.p ? b.p : "", b.len);
}

static V map_case(Args *a, int upper)
{
    Str *s = SELF;
    Str *r;
    int i;
    unpack_positional(a, 0, 0);
    ascii_only(a);
    r = (Str *)mk_str(s->s, s->len);
    for (i = 0; i < r->len; i++)
        r->s[i] = (char)(upper ? to_upper((unsigned char)r->s[i]) : to_lower((unsigned char)r->s[i]));
    return (V)r;
}
static V s_lower(Args *a) { return map_case(a, 0); }
static V s_upper(Args *a) { return map_case(a, 1); }

static V s_title(Args *a)
{
    Str *s = SELF;
    Str *r;
    int i, prev = 0;
    unpack_positional(a, 0, 0);
    ascii_only(a);
    r = (Str *)mk_str(s->s, s->len);
    for (i = 0; i < r->len; i++) {
        int c = (unsigned char)r->s[i];
        if (is_alpha(c)) {
            r->s[i] = (char)(prev ? to_lower(c) : to_upper(c));
            prev = 1;
        } else {
            prev = 0;
        }
    }
    return (V)r;
}

static V strip_impl(Args *a, int left, int right)
{
    V chars = NULL;
    Str *s = SELF, *cs = NULL;
    int from = 0, to = s->len;
    unpack_positional(a, 0, 1, &chars);
    if (chars && chars != None)
        cs = want_str(chars, a->name);
    if (cs && cs->len == 0)
        cs = NULL;      /* as in starlark-go: "" means whitespace */
#define STRIPPABLE(c) (cs ? memchr(cs->s, (c), cs->len) != NULL : is_space((unsigned char)(c)))
    if (left)
        while (from < to && STRIPPABLE(s->s[from]))
            from++;
    if (right)
        while (to > from && STRIPPABLE(s->s[to - 1]))
            to--;
#undef STRIPPABLE
    return substr(s, from, to);
}
static V s_strip(Args *a) { return strip_impl(a, 1, 1); }
static V s_lstrip(Args *a) { return strip_impl(a, 1, 0); }
static V s_rstrip(Args *a) { return strip_impl(a, 0, 1); }

static V partition_impl(Args *a, int right)
{
    V sepv;
    Str *s = SELF, *sep;
    int i;
    V t = mk_tuple(3);
    unpack_positional(a, 1, 1, &sepv);
    sep = want_str(sepv, a->name);
    if (sep->len == 0)
        star_error("%s: empty separator", a->name);
    i = find_sub(s->s, s->len, sep->s, sep->len, right);
    if (i < 0) {
        V empty = mk_str("", 0);
        if (right) {
            AS_TUPLE(t)->items[0] = empty;
            AS_TUPLE(t)->items[1] = empty;
            AS_TUPLE(t)->items[2] = (V)s;
        } else {
            AS_TUPLE(t)->items[0] = (V)s;
            AS_TUPLE(t)->items[1] = empty;
            AS_TUPLE(t)->items[2] = empty;
        }
        return t;
    }
    AS_TUPLE(t)->items[0] = substr(s, 0, i);
    AS_TUPLE(t)->items[1] = (V)sep;
    AS_TUPLE(t)->items[2] = substr(s, i + sep->len, s->len);
    return t;
}
static V s_partition(Args *a) { return partition_impl(a, 0); }
static V s_rpartition(Args *a) { return partition_impl(a, 1); }

static V s_removeprefix(Args *a)
{
    V x;
    Str *s = SELF, *p;
    unpack_positional(a, 1, 1, &x);
    p = want_str(x, "removeprefix");
    if (p->len <= s->len && memcmp(s->s, p->s, p->len) == 0)
        return substr(s, p->len, s->len);
    return (V)s;
}

static V s_removesuffix(Args *a)
{
    V x;
    Str *s = SELF, *p;
    unpack_positional(a, 1, 1, &x);
    p = want_str(x, "removesuffix");
    if (p->len <= s->len && memcmp(s->s + s->len - p->len, p->s, p->len) == 0)
        return substr(s, 0, s->len - p->len);
    return (V)s;
}

static V s_replace(Args *a)
{
    V ov, nv, cv = NULL;
    Str *s = SELF, *o, *n;
    int64_t count = -1;
    Buf b;
    int i = 0;
    unpack_positional(a, 2, 3, &ov, &nv, &cv);
    o = want_str(ov, "replace");
    n = want_str(nv, "replace");
    if (cv)
        count = want_int(cv, "replace");
    buf_init(&b);
    if (o->len == 0) {
        /* insert before every element and at the end */
        for (i = 0; i <= s->len; i++) {
            if (count != 0) {
                buf_put(&b, n->s, n->len);
                if (count > 0)
                    count--;
            }
            if (i < s->len)
                buf_putc(&b, s->s[i]);
        }
        return mk_str(b.p ? b.p : "", b.len);
    }
    while (i < s->len) {
        if (count != 0 && i + o->len <= s->len && memcmp(s->s + i, o->s, o->len) == 0) {
            buf_put(&b, n->s, n->len);
            i += o->len;
            if (count > 0)
                count--;
        } else {
            buf_putc(&b, s->s[i++]);
        }
    }
    return mk_str(b.p ? b.p : "", b.len);
}

static V split_impl(Args *a, int right)
{
    V sepv = NULL, maxv = NULL, l = mk_list(0);
    Str *s = SELF, *sep = NULL;
    int64_t max = -1;
    unpack_args(a, "sep?", &sepv, "maxsplit?", &maxv, NULL);
    if (sepv && sepv != None)
        sep = want_str(sepv, a->name);
    if (maxv && maxv != None)
        max = want_int(maxv, a->name);
    if (sep && sep->len == 0)
        star_error("%s: empty separator", a->name);
    if (!right) {
        int i = 0;
        if (!sep) {
            while (i < s->len) {
                int j;
                while (i < s->len && is_space((unsigned char)s->s[i]))
                    i++;
                if (i >= s->len)
                    break;
                if (max == 0) {
                    list_append(l, mk_str(s->s + i, s->len - i));
                    break;
                }
                j = i;
                while (j < s->len && !is_space((unsigned char)s->s[j]))
                    j++;
                list_append(l, mk_str(s->s + i, j - i));
                if (max > 0)
                    max--;
                i = j;
            }
            return l;
        }
        for (;;) {
            int k = max == 0 ? -1 : find_sub(s->s + i, s->len - i, sep->s, sep->len, 0);
            if (k < 0) {
                list_append(l, mk_str(s->s + i, s->len - i));
                return l;
            }
            list_append(l, mk_str(s->s + i, k));
            i += k + sep->len;
            if (max > 0)
                max--;
        }
    }
    /* rsplit: collect from the right, then reverse */
    {
        int end = s->len, n, k;
        if (!sep) {
            while (end > 0) {
                int j;
                while (end > 0 && is_space((unsigned char)s->s[end - 1]))
                    end--;
                if (end == 0)
                    break;
                if (max == 0) {
                    list_append(l, mk_str(s->s, end));
                    break;
                }
                j = end;
                while (j > 0 && !is_space((unsigned char)s->s[j - 1]))
                    j--;
                list_append(l, mk_str(s->s + j, end - j));
                if (max > 0)
                    max--;
                end = j;
            }
        } else {
            for (;;) {
                k = max == 0 ? -1 : find_sub(s->s, end, sep->s, sep->len, 1);
                if (k < 0) {
                    list_append(l, mk_str(s->s, end));
                    break;
                }
                list_append(l, mk_str(s->s + k + sep->len, end - k - sep->len));
                end = k;
                if (max > 0)
                    max--;
            }
        }
        n = AS_LIST(l)->len;
        for (k = 0; k < n / 2; k++) {
            V t = AS_LIST(l)->items[k];
            AS_LIST(l)->items[k] = AS_LIST(l)->items[n - 1 - k];
            AS_LIST(l)->items[n - 1 - k] = t;
        }
        return l;
    }
}
static V s_split(Args *a) { return split_impl(a, 0); }
static V s_rsplit(Args *a) { return split_impl(a, 1); }

static V s_splitlines(Args *a)
{
    V kv = NULL, l = mk_list(0);
    Str *s = SELF;
    int keep = 0, i = 0, start = 0;
    unpack_args(a, "keepends?", &kv, NULL);
    if (kv) {
        if (TYPE(kv) != T_BOOL)
            star_error("splitlines: for parameter keepends: got %s, want bool", type_name(kv));
        keep = truth(kv);
    }
    while (i < s->len) {
        if (s->s[i] == '\n' || s->s[i] == '\r') {
            int eol = i;
            if (s->s[i] == '\r' && i + 1 < s->len && s->s[i + 1] == '\n')
                i++;
            i++;
            list_append(l, mk_str(s->s + start, (keep ? i : eol) - start));
            start = i;
        } else {
            i++;
        }
    }
    if (start < s->len)
        list_append(l, mk_str(s->s + start, s->len - start));
    return l;
}

typedef struct SMethod { const char *name; BuiltinFn fn; } SMethod;

static const SMethod methods[] = {
    {"capitalize", s_capitalize}, {"codepoint_ords", s_codepoint_ords},
    {"codepoints", s_codepoints}, {"count", s_count}, {"elem_ords", s_elem_ords},
    {"elems", s_elems}, {"endswith", s_endswith}, {"find", s_find},
    {"format", s_format}, {"index", s_index}, {"isalnum", s_isalnum},
    {"isalpha", s_isalpha}, {"isdigit", s_isdigit}, {"islower", s_islower},
    {"isspace", s_isspace}, {"istitle", s_istitle}, {"isupper", s_isupper},
    {"join", s_join}, {"lower", s_lower}, {"lstrip", s_lstrip},
    {"partition", s_partition}, {"removeprefix", s_removeprefix},
    {"removesuffix", s_removesuffix}, {"replace", s_replace}, {"rfind", s_rfind},
    {"rindex", s_rindex}, {"rpartition", s_rpartition}, {"rsplit", s_rsplit},
    {"rstrip", s_rstrip}, {"split", s_split}, {"splitlines", s_splitlines},
    {"startswith", s_startswith}, {"strip", s_strip}, {"title", s_title},
    {"upper", s_upper}, {NULL, NULL}
};

V string_method(V recv, Str *name)
{
    int i;
    for (i = 0; methods[i].name; i++)
        if (str_eq(name, methods[i].name))
            return mk_builtin(methods[i].name, methods[i].fn, recv);
    return NULL;
}

void string_methods(V list)
{
    int i;
    for (i = 0; methods[i].name; i++)
        list_append(list, (V)intern(methods[i].name));
}

/* ----------------------------------------------------------- str.format -- */

V string_format(Str *fmt, Args *a)
{
    Buf b;
    const char *p = fmt->s, *end = fmt->s + fmt->len;
    int index = 0, autoidx = 0, manual = 0;
    buf_init(&b);
    while (p < end) {
        const char *q, *field_end;
        Str *name;
        const char *conv = "s", *spec = NULL;
        int convlen = 1, namelen, speclen = 0;
        V arg = NULL;
        if (*p == '}') {
            if (p + 1 < end && p[1] == '}') {
                buf_putc(&b, '}');
                p += 2;
                continue;
            }
            star_error("format: single '}' in format");
        }
        if (*p != '{') {
            buf_putc(&b, *p++);
            continue;
        }
        if (p + 1 < end && p[1] == '{') {
            buf_putc(&b, '{');
            p += 2;
            continue;
        }
        p++;
        for (q = p; q < end && *q != '}'; q++)
            ;
        if (q >= end)
            star_error("format: unmatched '{' in format");
        field_end = q;
        /* name[!conv][:spec] */
        for (q = p; q < field_end && *q != '!' && *q != ':'; q++)
            ;
        namelen = (int)(q - p);
        name = intern_n(p, namelen);
        if (q < field_end && *q == '!') {
            const char *c = q + 1, *cend = c;
            while (cend < field_end && *cend != ':')
                cend++;
            conv = c;
            convlen = (int)(cend - c);
            q = cend;
        }
        if (q < field_end && *q == ':') {
            spec = q + 1;
            speclen = (int)(field_end - spec);
        }
        p = field_end + 1;
        if (namelen == 0) {
            if (manual)
                star_error("format: cannot switch from manual field specification to automatic field numbering");
            autoidx = 1;
            if (index >= a->npos)
                star_error("format: tuple index out of range");
            arg = a->pos[index++];
        } else {
            int k, digits = 1;
            for (k = 0; k < namelen; k++)
                if (!is_digit((unsigned char)name->s[k]))
                    digits = 0;
            if (digits) {
                int64_t num = 0;
                if (autoidx)
                    star_error("format: cannot switch from automatic field numbering to manual field specification");
                manual = 1;
                for (k = 0; k < namelen && num < 1000000; k++)
                    num = num * 10 + (name->s[k] - '0');
                if (num >= a->npos)
                    star_error("format: tuple index out of range");
                arg = a->pos[num];
            } else {
                for (k = 0; k < a->nkw; k++)
                    if (a->kwnames[k] == name)
                        arg = a->kwvals[k];
                if (!arg) {
                    if (memchr(name->s, '.', namelen))
                        star_error("format: attribute syntax x.y is not supported in replacement fields: %s", name->s);
                    if (memchr(name->s, '[', namelen))
                        star_error("format: element syntax a[i] is not supported in replacement fields: %s", name->s);
                    if (memchr(name->s, '{', namelen))
                        star_error("format: nested replacement fields not supported");
                    star_error("format: keyword %s not found", name->s);
                }
            }
        }
        if (spec && speclen)
            star_error("format spec features not supported in replacement fields: %.*s", speclen, spec);
        if (convlen == 1 && conv[0] == 's')
            str_to(&b, arg);
        else if (convlen == 1 && conv[0] == 'r')
            repr_to(&b, arg);
        else
            star_error("format: unknown conversion \"%.*s\"", convlen, conv);
    }
    return mk_str(b.p ? b.p : "", b.len);
}

/* ------------------------------------------------------------ % operator -- */

static void put_int(Buf *b, int64_t v, int base, int upper)
{
    char tmp[80];
    int n = 0;
    uint64_t u;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (v < 0) {
        buf_putc(b, '-');
        u = (uint64_t)0 - (uint64_t)v;
    } else {
        u = (uint64_t)v;
    }
    do {
        tmp[n++] = digits[u % base];
        u /= base;
    } while (u);
    while (n)
        buf_putc(b, tmp[--n]);
}

V string_percent(Str *fmt, V x)
{
    Buf b;
    const char *p = fmt->s, *end = fmt->s + fmt->len;
    int index = 0, nargs = TYPE(x) == T_TUPLE ? AS_TUPLE(x)->len : 1;
    buf_init(&b);
    while (p < end) {
        V arg;
        int c;
        if (*p != '%') {
            buf_putc(&b, *p++);
            continue;
        }
        p++;
        if (p < end && *p == '%') {
            buf_putc(&b, '%');
            p++;
            continue;
        }
        if (p < end && *p == '(') {
            const char *q = ++p;
            V k;
            while (q < end && *q != ')')
                q++;
            if (q >= end)
                star_error("incomplete format key");
            if (TYPE(x) != T_DICT)
                star_error("format requires a mapping");
            k = mk_str(p, (int)(q - p));
            arg = dict_get(x, k);
            if (!arg)
                star_error("key not found: %s", AS_STR(k)->s);
            p = q + 1;
        } else {
            if (index >= nargs)
                star_error("not enough arguments for format string");
            arg = TYPE(x) == T_TUPLE ? AS_TUPLE(x)->items[index] : x;
        }
        if (p >= end)
            star_error("incomplete format");
        c = (unsigned char)*p++;
        switch (c) {
        case 's':
            str_to(&b, arg);
            break;
        case 'r':
            repr_to(&b, arg);
            break;
        case 'd': case 'i': case 'o': case 'x': case 'X':
            if (TYPE(arg) != T_INT)
                star_error("%%%c format requires integer: cannot convert %s to int", c, type_name(arg));
            put_int(&b, AS_INT(arg), c == 'o' ? 8 : (c == 'x' || c == 'X') ? 16 : 10, c == 'X');
            break;
        case 'e': case 'f': case 'g': case 'E': case 'F': case 'G':
            star_error("%%%c format: floating-point numbers are not supported", c);
            break;
        case 'c':
            if (TYPE(arg) == T_INT) {
                char enc[4];
                int64_t cp = AS_INT(arg);
                if (cp < 0 || cp > 0x10FFFF)
                    star_error("%%c format requires a valid Unicode code point, got %lld", (long long)cp);
                buf_put(&b, enc, utf8_encode(enc, (int)cp));
            } else if (TYPE(arg) == T_STRING) {
                int cp, n = AS_STR(arg)->len ?
                    utf8_decode((unsigned char *)AS_STR(arg)->s, AS_STR(arg)->len, &cp) : 0;
                if (n == 0 || n != AS_STR(arg)->len)
                    star_error("%%c format requires a single-character string");
                buf_put(&b, AS_STR(arg)->s, n);
            } else {
                star_error("%%c format requires int or single-character string, not %s", type_name(arg));
            }
            break;
        default:
            star_error("unknown conversion %%%c", c);
        }
        index++;
    }
    if (index < nargs && TYPE(x) != T_DICT)
        star_error("too many arguments for format string");
    return mk_str(b.p ? b.p : "", b.len);
}
