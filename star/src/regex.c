/* SPDX-License-Identifier: MIT
 * regex.c -- a small backtracking matcher for an RE2-flavoured subset:
 * literals, ., [classes], \d\w\s (and negations), ^ $, groups (?:), |,
 * * + ? {n,m} and their lazy forms. Used by the conformance harness
 * (matches(), expected-error patterns). Unanchored search, like Go's
 * regexp.MatchString. */

#include <string.h>
#include "star.h"

enum { R_CHAR, R_ANY, R_CLASS, R_BOL, R_EOL, R_SEQ, R_ALT, R_REP };

typedef struct RNode {
    int kind;
    int c;
    unsigned char set[32];
    int min, max, greedy;
    struct RNode **kids;
    int nkids;
    struct RNode *sub;
} RNode;

typedef struct RParser {
    const char *p, *end;
    char *err;
} RParser;

static RNode *rnew(int kind)
{
    RNode *n = arena_alloc(sizeof(RNode));
    n->kind = kind;
    return n;
}

static void rpush(RNode *n, RNode *k)
{
    n->kids = arena_grow(n->kids, sizeof(RNode *) * n->nkids, sizeof(RNode *) * (n->nkids + 1));
    n->kids[n->nkids++] = k;
}

static void set_add(unsigned char *set, int c) { set[c >> 3] |= (unsigned char)(1 << (c & 7)); }
static int set_has(const unsigned char *set, int c) { return set[c >> 3] & (1 << (c & 7)); }

static void add_perl_class(unsigned char *set, int cls)
{
    int c;
    for (c = 0; c < 256; c++) {
        int in = 0;
        switch (cls | 32) {
        case 'd': in = c >= '0' && c <= '9'; break;
        case 'w': in = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; break;
        case 's': in = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; break;
        }
        if (cls >= 'A' && cls <= 'Z')
            in = !in;
        if (in)
            set_add(set, c);
    }
}

static int esc_char(int c)
{
    switch (c) {
    case 'n': return '\n';
    case 't': return '\t';
    case 'r': return '\r';
    case 'f': return '\f';
    case 'v': return '\v';
    case 'a': return 7;
    }
    return c;
}

static RNode *parse_alt(RParser *rp);

static RNode *parse_atom(RParser *rp)
{
    int c = (unsigned char)*rp->p++;
    RNode *n;
    switch (c) {
    case '(':
        if (rp->end - rp->p >= 2 && rp->p[0] == '?' && rp->p[1] == ':')
            rp->p += 2;
        n = parse_alt(rp);
        if (rp->p >= rp->end || *rp->p != ')') {
            rp->err = "missing closing )";
            return NULL;
        }
        rp->p++;
        return n;
    case '.':
        return rnew(R_ANY);
    case '^':
        return rnew(R_BOL);
    case '$':
        return rnew(R_EOL);
    case '[': {
        int neg = 0, first = 1, i;
        n = rnew(R_CLASS);
        if (rp->p < rp->end && *rp->p == '^') {
            neg = 1;
            rp->p++;
        }
        while (rp->p < rp->end && (*rp->p != ']' || first)) {
            int lo = (unsigned char)*rp->p++, hi;
            first = 0;
            if (lo == '\\' && rp->p < rp->end) {
                int e = (unsigned char)*rp->p++;
                if (strchr("dDwWsS", e)) {
                    add_perl_class(n->set, e);
                    continue;
                }
                lo = esc_char(e);
            } else if (lo == '[' && rp->p < rp->end && *rp->p == ':') {
                rp->err = "POSIX classes are not supported";
                return NULL;
            }
            hi = lo;
            if (rp->p + 1 < rp->end && *rp->p == '-' && rp->p[1] != ']') {
                rp->p++;
                hi = (unsigned char)*rp->p++;
                if (hi == '\\' && rp->p < rp->end)
                    hi = esc_char((unsigned char)*rp->p++);
            }
            for (i = lo; i <= hi; i++)
                set_add(n->set, i);
        }
        if (rp->p >= rp->end) {
            rp->err = "missing closing ]";
            return NULL;
        }
        rp->p++;
        if (neg)
            for (i = 0; i < 32; i++)
                n->set[i] = (unsigned char)~n->set[i];
        return n;
    }
    case '\\':
        if (rp->p >= rp->end) {
            rp->err = "trailing backslash";
            return NULL;
        }
        c = (unsigned char)*rp->p++;
        if (strchr("dDwWsS", c)) {
            n = rnew(R_CLASS);
            add_perl_class(n->set, c);
            return n;
        }
        n = rnew(R_CHAR);
        n->c = esc_char(c);
        return n;
    case '*': case '+': case '?':
        rp->err = "missing argument to repetition operator";
        return NULL;
    }
    n = rnew(R_CHAR);
    n->c = c;
    return n;
}

static int parse_num(RParser *rp, int *out)
{
    int v = 0, any = 0;
    while (rp->p < rp->end && *rp->p >= '0' && *rp->p <= '9') {
        v = v * 10 + (*rp->p++ - '0');
        any = 1;
    }
    *out = v;
    return any;
}

static RNode *parse_seq(RParser *rp)
{
    RNode *seq = rnew(R_SEQ);
    while (rp->p < rp->end && *rp->p != '|' && *rp->p != ')') {
        RNode *a = parse_atom(rp), *r;
        if (!a)
            return NULL;
        for (;;) {
            int min, max;
            const char *save = rp->p;
            if (rp->p >= rp->end)
                break;
            if (*rp->p == '*') { min = 0; max = -1; rp->p++; }
            else if (*rp->p == '+') { min = 1; max = -1; rp->p++; }
            else if (*rp->p == '?') { min = 0; max = 1; rp->p++; }
            else if (*rp->p == '{') {
                rp->p++;
                if (!parse_num(rp, &min)) {
                    rp->p = save;
                    break;
                }
                max = min;
                if (rp->p < rp->end && *rp->p == ',') {
                    rp->p++;
                    if (!parse_num(rp, &max))
                        max = -1;
                }
                if (rp->p >= rp->end || *rp->p != '}') {
                    rp->p = save;
                    break;
                }
                rp->p++;
            } else
                break;
            r = rnew(R_REP);
            r->sub = a;
            r->min = min;
            r->max = max;
            r->greedy = 1;
            if (rp->p < rp->end && *rp->p == '?') {
                r->greedy = 0;
                rp->p++;
            }
            a = r;
        }
        rpush(seq, a);
    }
    return seq;
}

static RNode *parse_alt(RParser *rp)
{
    RNode *first = parse_seq(rp), *alt;
    if (!first)
        return NULL;
    if (rp->p >= rp->end || *rp->p != '|')
        return first;
    alt = rnew(R_ALT);
    rpush(alt, first);
    while (rp->p < rp->end && *rp->p == '|') {
        RNode *s;
        rp->p++;
        s = parse_seq(rp);
        if (!s)
            return NULL;
        rpush(alt, s);
    }
    return alt;
}

/* ----------------------------------------------------------- matching -- */

enum { K_SEQ, K_REP };

typedef struct Cont {
    int kind;
    RNode **items;
    int i, n;
    RNode *rep;
    int count, start;
    struct Cont *next;
} Cont;

typedef struct MState { const char *s; int len; int steps; } MState;

static int m_node(MState *m, RNode *nd, int pos, Cont *k);
static int m_rep(MState *m, RNode *nd, int count, int pos, Cont *next);

static int m_cont(MState *m, int pos, Cont *k)
{
    if (!k)
        return 1;
    if (++m->steps > 2000000)
        return 0;
    if (k->kind == K_SEQ) {
        Cont k2;
        if (k->i == k->n)
            return m_cont(m, pos, k->next);
        k2 = *k;
        k2.i++;
        return m_node(m, k->items[k->i], pos, &k2);
    }
    /* one more iteration of a repetition just matched */
    if (pos == k->start && k->count > k->rep->min)
        return m_cont(m, pos, k->next);   /* empty iteration: stop looping */
    return m_rep(m, k->rep, k->count, pos, k->next);
}

static int m_rep(MState *m, RNode *nd, int count, int pos, Cont *next)
{
    Cont c;
    int more = nd->max < 0 || count < nd->max;
    c.kind = K_REP;
    c.rep = nd;
    c.count = count + 1;
    c.start = pos;
    c.next = next;
    if (count < nd->min)
        return m_node(m, nd->sub, pos, &c);
    if (nd->greedy) {
        if (more && m_node(m, nd->sub, pos, &c))
            return 1;
        return m_cont(m, pos, next);
    }
    if (m_cont(m, pos, next))
        return 1;
    return more && m_node(m, nd->sub, pos, &c);
}

static int m_node(MState *m, RNode *nd, int pos, Cont *k)
{
    int i;
    switch (nd->kind) {
    case R_CHAR:
        return pos < m->len && (unsigned char)m->s[pos] == nd->c && m_cont(m, pos + 1, k);
    case R_ANY:
        return pos < m->len && m->s[pos] != '\n' && m_cont(m, pos + 1, k);
    case R_CLASS:
        return pos < m->len && set_has(nd->set, (unsigned char)m->s[pos]) && m_cont(m, pos + 1, k);
    case R_BOL:
        return pos == 0 && m_cont(m, pos, k);
    case R_EOL:
        return pos == m->len && m_cont(m, pos, k);
    case R_SEQ: {
        Cont c;
        c.kind = K_SEQ;
        c.items = nd->kids;
        c.i = 0;
        c.n = nd->nkids;
        c.next = k;
        return m_cont(m, pos, &c);
    }
    case R_ALT:
        for (i = 0; i < nd->nkids; i++)
            if (m_node(m, nd->kids[i], pos, k))
                return 1;
        return 0;
    case R_REP:
        return m_rep(m, nd, 0, pos, k);
    }
    return 0;
}

int regex_match(const char *pattern, const char *s, int slen, char **err)
{
    RParser rp;
    RNode *root;
    MState m;
    int i;
    rp.p = pattern;
    rp.end = pattern + strlen(pattern);
    rp.err = NULL;
    root = parse_alt(&rp);
    if (!root || rp.p != rp.end) {
        *err = rp.err ? rp.err : "unexpected )";
        return -1;
    }
    m.s = s;
    m.len = slen;
    m.steps = 0;
    for (i = 0; i <= slen; i++)
        if (m_node(&m, root, i, NULL))
            return 1;
    return 0;
}
