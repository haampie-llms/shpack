/* SPDX-License-Identifier: MIT
 * parse.c -- recursive-descent parser producing the AST in star.h. The
 * precedence scheme follows starlark-go's syntax/parse.go so that operator
 * associativity and the "does not associate" errors agree with it. */

#include <stdio.h>
#include <string.h>
#include "star.h"
#include "lex.h"

typedef struct Parser {
    const char *file;
    Token *toks;
    int ntoks, i;
    int pending_not_in;     /* NOT followed by IN seen, rewritten to T_NOT_IN */
    ErrList *errs;
    jmp_buf jb;
} Parser;

static void perr(Parser *p, int line, int col, const char *fmt, ...)
{
    va_list ap;
    char tmp[512];
    ErrList *e = p->errs;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    e->pos = arena_grow(e->pos, sizeof(Pos) * e->n, sizeof(Pos) * (e->n + 1));
    e->msg = arena_grow(e->msg, sizeof(char *) * e->n, sizeof(char *) * (e->n + 1));
    e->pos[e->n].file = p->file;
    e->pos[e->n].line = line;
    e->pos[e->n].col = col;
    e->msg[e->n] = arena_strdup(tmp);
    e->n++;
    longjmp(p->jb, 1);
}

static Token *cur(Parser *p) { return &p->toks[p->i]; }
static int tok(Parser *p) { return p->pending_not_in ? T_NOT_IN : p->toks[p->i].kind; }

static Token *advance(Parser *p)
{
    Token *t = &p->toks[p->i];
    if (p->pending_not_in) {
        p->pending_not_in = 0;   /* the IN token itself is consumed below */
    }
    if (t->kind != T_EOF)
        p->i++;
    return t;
}

static const char *tokdesc(Parser *p)
{
    Token *t = cur(p);
    static char buf[64];
    if (t->kind == T_IDENT) {
        snprintf(buf, sizeof buf, "%.40s", t->s->s);
        return buf;
    }
    return token_str(t->kind);
}

static Token *expect(Parser *p, int kind)
{
    if (tok(p) != kind)
        perr(p, cur(p)->line, cur(p)->col, "got %s, want %s", tokdesc(p), token_str(kind));
    return advance(p);
}

static Node *mknode(int kind, Token *t)
{
    Node *n = arena_alloc(sizeof(Node));
    n->kind = kind;
    n->line = t->line;
    n->col = t->col;
    return n;
}

typedef struct NodeVec { Node **v; int n, cap; } NodeVec;

static void push(NodeVec *nv, Node *x)
{
    if (nv->n == nv->cap) {
        int nc = nv->cap ? nv->cap * 2 : 8;
        nv->v = arena_grow(nv->v, sizeof(Node *) * nv->cap, sizeof(Node *) * nc);
        nv->cap = nc;
    }
    nv->v[nv->n++] = x;
}

static Node *parse_test(Parser *p);
static Node *parse_expr(Parser *p, int in_paren);
static Node *parse_binop(Parser *p, int prec);
static Node *parse_primary_suffix(Parser *p);
static void parse_stmt(Parser *p, NodeVec *out);
static void parse_suite(Parser *p, NodeVec *out);

static int precedence(int t)
{
    switch (t) {
    case T_OR: return 0;
    case T_AND: return 1;
    case T_NOT: return 2;
    case T_EQL: case T_NEQ: case T_LT: case T_GT: case T_LE: case T_GE:
    case T_IN: case T_NOT_IN: return 3;
    case T_PIPE: return 4;
    case T_CIRCUMFLEX: return 5;
    case T_AMP: return 6;
    case T_LTLT: case T_GTGT: return 7;
    case T_MINUS: case T_PLUS: return 8;
    case T_STAR: case T_PERCENT: case T_SLASH: case T_SLASHSLASH: return 9;
    }
    return -1;
}
#define NPREC 10

/* parameters: def f(a, b=1, *args, c, **kw) and lambda a, b=1: ... */
static FuncInfo *parse_params(Parser *p, int closer)
{
    FuncInfo *fi = arena_alloc(sizeof(FuncInfo));
    NodeVec params = {0};
    int seen_star = 0, seen_kwargs = 0, seen_default = 0, bare_star = 0;
    while (tok(p) != closer) {
        Token *t = cur(p);
        Node *prm;
        if (seen_kwargs)
            perr(p, t->line, t->col, "parameter may not follow **kwargs");
        if (tok(p) == T_STARSTAR) {
            advance(p);
            prm = mknode(N_PARAM_STARSTAR, t);
            prm->s = expect(p, T_IDENT)->s;
            seen_kwargs = 1;
            fi->has_kwargs = 1;
        } else if (tok(p) == T_STAR) {
            advance(p);
            if (seen_star)
                perr(p, t->line, t->col, "multiple * parameters not allowed");
            seen_star = 1;
            prm = mknode(N_PARAM_STAR, t);
            if (tok(p) == T_IDENT) {
                prm->s = advance(p)->s;
                fi->has_varargs = 1;
            } else {
                bare_star = 1;
            }
        } else {
            prm = mknode(N_PARAM, t);
            prm->s = expect(p, T_IDENT)->s;
            if (tok(p) == T_EQ) {
                advance(p);
                prm->a = parse_test(p);
                if (!seen_star)
                    seen_default = 1;
            } else if (seen_default && !seen_star) {
                perr(p, t->line, t->col, "required parameter may not follow optional");
            }
            if (seen_star) {
                fi->nkwonly++;
                bare_star = 0;
            } else {
                fi->npositional++;
            }
        }
        push(&params, prm);
        if (tok(p) != T_COMMA)
            break;
        advance(p);
    }
    if (bare_star)
        perr(p, cur(p)->line, cur(p)->col, "bare * must be followed by keyword-only parameters");
    fi->params = params.v;
    fi->nparams = params.n;
    fi->filename = p->file;
    return fi;
}

static Node *parse_lambda(Parser *p, int allow_cond)
{
    Token *t = expect(p, T_LAMBDA);
    Node *n = mknode(N_LAMBDA, t);
    FuncInfo *fi = parse_params(p, T_COLON);
    expect(p, T_COLON);
    fi->expr = allow_cond ? parse_test(p) : parse_binop(p, 0);
    fi->name = intern("lambda");
    fi->line = t->line;
    fi->col = t->col;
    n->fn = fi;
    return n;
}

/* Test = LambdaExpr | IfExpr | BinaryExpr ... */
static Node *parse_test(Parser *p)
{
    Node *x, *n;
    Token *t;
    if (tok(p) == T_LAMBDA)
        return parse_lambda(p, 1);
    x = parse_binop(p, 0);
    if (tok(p) == T_IF) {
        t = advance(p);
        n = mknode(N_COND, t);
        n->a = x;
        n->b = parse_binop(p, 0);
        if (tok(p) != T_ELSE)
            perr(p, cur(p)->line, cur(p)->col, "conditional expression without else clause");
        advance(p);
        n->c = parse_test(p);
        return n;
    }
    return x;
}

static Node *parse_test_nocond(Parser *p)
{
    if (tok(p) == T_LAMBDA)
        return parse_lambda(p, 0);
    return parse_binop(p, 0);
}

static Node *parse_binop(Parser *p, int prec)
{
    Node *x;
    int first;
    if (prec >= NPREC)
        return parse_primary_suffix(p);
    if (tok(p) == T_NOT && prec == precedence(T_NOT)) {
        Token *t = advance(p);
        Node *n = mknode(N_UNARY, t);
        n->op = T_NOT;
        n->a = parse_binop(p, prec);
        return n;
    }
    x = parse_binop(p, prec + 1);
    for (first = 1;; first = 0) {
        int op, opprec;
        Token *t;
        Node *n;
        if (tok(p) == T_NOT && !p->pending_not_in) {
            /* in operator position, NOT must be followed by IN */
            Token *nt = advance(p);
            if (cur(p)->kind != T_IN)
                perr(p, cur(p)->line, cur(p)->col, "got %s, want in", tokdesc(p));
            (void)nt;
            p->pending_not_in = 1;
        }
        op = tok(p);
        opprec = precedence(op);
        if (opprec < prec)
            return x;
        if (!first && opprec == precedence(T_EQL))
            perr(p, cur(p)->line, cur(p)->col, "%s does not associate with %s (use parens)",
                 token_str(x->op), token_str(op));
        t = cur(p);
        if (p->pending_not_in) {
            p->pending_not_in = 0;
            advance(p);     /* the IN */
        } else {
            advance(p);
        }
        n = mknode(N_BINARY, t);
        n->op = op;
        n->a = x;
        n->b = parse_binop(p, opprec + 1);
        x = n;
    }
}

static void parse_call_args(Parser *p, Node *call)
{
    NodeVec args = {0};
    int seen_kw = 0, seen_star = 0, seen_starstar = 0;
    while (tok(p) != T_RPAREN) {
        Token *t = cur(p);
        Node *a;
        if (tok(p) == T_STARSTAR) {
            advance(p);
            a = mknode(N_STARSTARARG, t);
            a->a = parse_test(p);
            if (seen_starstar)
                perr(p, t->line, t->col, "multiple **kwargs not allowed");
            seen_starstar = 1;
        } else if (tok(p) == T_STAR) {
            advance(p);
            a = mknode(N_STARARG, t);
            a->a = parse_test(p);
            if (seen_star)
                perr(p, t->line, t->col, "multiple *args not allowed");
            if (seen_starstar)
                perr(p, t->line, t->col, "*args may not follow **kwargs");
            seen_star = 1;
        } else {
            Node *x = parse_test(p);
            if (tok(p) == T_EQ) {
                if (x->kind != N_IDENT)
                    perr(p, cur(p)->line, cur(p)->col, "keyword argument must have form name=expr");
                advance(p);
                a = mknode(N_KWARG, t);
                a->s = x->s;
                a->a = parse_test(p);
                if (seen_starstar)
                    perr(p, t->line, t->col, "keyword argument may not follow **kwargs");
                seen_kw = 1;
            } else {
                a = x;
                if (seen_kw)
                    perr(p, t->line, t->col, "positional argument may not follow named");
                if (seen_star)
                    perr(p, t->line, t->col, "positional argument may not follow *args");
                if (seen_starstar)
                    perr(p, t->line, t->col, "positional argument may not follow **kwargs");
            }
        }
        push(&args, a);
        if (tok(p) != T_COMMA)
            break;
        advance(p);
    }
    call->list = args.v;
    call->n = args.n;
}

/* comprehension clauses after the body: for ... in ... [if ...] ... */
static void parse_comp_clauses(Parser *p, Node *comp)
{
    NodeVec cl = {0};
    while (tok(p) == T_FOR || tok(p) == T_IF) {
        Token *t = advance(p);
        Node *c;
        if (t->kind == T_FOR) {
            NodeVec vars = {0};
            c = mknode(N_FORCLAUSE, t);
            for (;;) {
                push(&vars, parse_primary_suffix(p));
                if (tok(p) != T_COMMA)
                    break;
                advance(p);
                if (tok(p) == T_IN)
                    break;
            }
            if (vars.n == 1 && cur(p)[-1].kind != T_COMMA) {
                c->a = vars.v[0];
            } else {
                c->a = mknode(N_TUPLE, t);
                c->a->list = vars.v;
                c->a->n = vars.n;
            }
            expect(p, T_IN);
            c->b = parse_binop(p, 0);
        } else {
            c = mknode(N_IFCLAUSE, t);
            c->a = parse_test_nocond(p);
        }
        push(&cl, c);
    }
    comp->list = cl.v;
    comp->n = cl.n;
}

static Node *parse_primary(Parser *p)
{
    Token *t = cur(p);
    Node *n;
    switch (tok(p)) {
    case T_IDENT:
        advance(p);
        n = mknode(N_IDENT, t);
        n->s = t->s;
        return n;
    case T_INTLIT:
        advance(p);
        n = mknode(N_INT, t);
        n->ival = t->ival;
        return n;
    case T_STRLIT:
        advance(p);
        n = mknode(N_STRING, t);
        n->s = t->s;
        return n;
    case T_LPAREN: {
        Node *x;
        advance(p);
        if (tok(p) == T_RPAREN) {
            advance(p);
            n = mknode(N_TUPLE, t);
            return n;
        }
        x = parse_expr(p, 1);
        expect(p, T_RPAREN);
        if (x->kind == N_TUPLE && x->line == -1) {
            /* tuple built by parse_expr from a comma list */
            x->line = t->line;
            x->col = t->col;
            return x;
        }
        n = mknode(N_PAREN, t);
        n->a = x;
        return n;
    }
    case T_LBRACK: {
        NodeVec el = {0};
        advance(p);
        n = mknode(N_LIST, t);
        if (tok(p) == T_RBRACK) {
            advance(p);
            return n;
        }
        push(&el, parse_test(p));
        if (tok(p) == T_FOR) {
            Node *c = mknode(N_COMP, t);
            c->op = T_LBRACK;
            c->a = el.v[0];
            parse_comp_clauses(p, c);
            expect(p, T_RBRACK);
            return c;
        }
        while (tok(p) == T_COMMA) {
            advance(p);
            if (tok(p) == T_RBRACK)
                break;
            push(&el, parse_test(p));
        }
        expect(p, T_RBRACK);
        n->list = el.v;
        n->n = el.n;
        return n;
    }
    case T_LBRACE: {
        NodeVec el = {0};
        Node *e;
        advance(p);
        n = mknode(N_DICT, t);
        if (tok(p) == T_RBRACE) {
            advance(p);
            return n;
        }
        for (;;) {
            Token *et = cur(p);
            e = mknode(N_ENTRY, et);
            e->a = parse_test(p);
            expect(p, T_COLON);
            e->b = parse_test(p);
            if (el.n == 0 && tok(p) == T_FOR) {
                Node *c = mknode(N_COMP, t);
                c->op = T_LBRACE;
                c->a = e;
                parse_comp_clauses(p, c);
                expect(p, T_RBRACE);
                return c;
            }
            push(&el, e);
            if (tok(p) != T_COMMA)
                break;
            advance(p);
            if (tok(p) == T_RBRACE)
                break;
        }
        expect(p, T_RBRACE);
        n->list = el.v;
        n->n = el.n;
        return n;
    }
    case T_MINUS: case T_PLUS: case T_TILDE:
        advance(p);
        n = mknode(N_UNARY, t);
        n->op = t->kind;
        n->a = parse_primary_suffix(p);
        return n;
    }
    perr(p, t->line, t->col, "got %s, want primary expression", tokdesc(p));
    return NULL;
}

static Node *parse_primary_suffix(Parser *p)
{
    Node *x = parse_primary(p);
    for (;;) {
        Token *t = cur(p);
        Node *n;
        switch (tok(p)) {
        case T_DOT:
            advance(p);
            n = mknode(N_DOT, t);
            n->a = x;
            n->s = expect(p, T_IDENT)->s;
            x = n;
            continue;
        case T_LBRACK: {
            Node *lo = NULL, *hi = NULL, *step = NULL;
            advance(p);
            if (tok(p) != T_COLON) {
                lo = parse_expr(p, 0);
                if (tok(p) == T_RBRACK) {
                    advance(p);
                    n = mknode(N_INDEX, t);
                    n->a = x;
                    n->b = lo;
                    x = n;
                    continue;
                }
            }
            expect(p, T_COLON);
            if (tok(p) != T_COLON && tok(p) != T_RBRACK)
                hi = parse_test(p);
            if (tok(p) == T_COLON) {
                advance(p);
                if (tok(p) != T_RBRACK)
                    step = parse_test(p);
            }
            expect(p, T_RBRACK);
            n = mknode(N_SLICE, t);
            n->a = x;
            n->b = lo;
            n->c = hi;
            n->d = step;
            x = n;
            continue;
        }
        case T_LPAREN:
            advance(p);
            n = mknode(N_CALL, t);
            n->a = x;
            parse_call_args(p, n);
            expect(p, T_RPAREN);
            x = n;
            continue;
        }
        return x;
    }
}

/* Expression = Test {',' Test} [','] -- a bare comma list is a tuple */
static Node *parse_expr(Parser *p, int in_paren)
{
    Token *t = cur(p);
    Node *x = parse_test(p), *tup;
    NodeVec el = {0};
    if (tok(p) != T_COMMA)
        return x;
    push(&el, x);
    while (tok(p) == T_COMMA) {
        advance(p);
        if (tok(p) == T_RPAREN || tok(p) == T_RBRACK || tok(p) == T_NEWLINE ||
            tok(p) == T_EQ || tok(p) == T_SEMI || tok(p) == T_COLON || tok(p) == T_EOF ||
            (tok(p) >= T_PLUS_EQ && tok(p) <= T_GTGT_EQ))
            break;
        push(&el, parse_test(p));
    }
    tup = mknode(N_TUPLE, t);
    tup->list = el.v;
    tup->n = el.n;
    if (in_paren)
        tup->line = -1;     /* marker for parse_primary */
    return tup;
}

static int valid_target(Node *x, int aug)
{
    switch (x->kind) {
    case N_IDENT: case N_INDEX: case N_DOT:
        return 1;
    case N_PAREN:
        return valid_target(x->a, aug);
    case N_TUPLE: case N_LIST: {
        int i;
        if (aug)
            return 0;
        for (i = 0; i < x->n; i++)
            if (!valid_target(x->list[i], 0))
                return 0;
        return 1;
    }
    }
    return 0;
}

static void parse_small_stmt(Parser *p, NodeVec *out)
{
    Token *t = cur(p);
    Node *n;
    switch (tok(p)) {
    case T_RETURN:
        advance(p);
        n = mknode(N_RETURN, t);
        if (tok(p) != T_NEWLINE && tok(p) != T_SEMI && tok(p) != T_EOF)
            n->a = parse_expr(p, 0);
        push(out, n);
        return;
    case T_BREAK:
        advance(p);
        push(out, mknode(N_BREAK, t));
        return;
    case T_CONTINUE:
        advance(p);
        push(out, mknode(N_CONTINUE, t));
        return;
    case T_PASS:
        advance(p);
        push(out, mknode(N_PASS, t));
        return;
    case T_LOAD: {
        /* load("module", "a", b="c", ...): list = N_STRING (module) then
         * N_KWARG pairs name=original */
        NodeVec items = {0};
        Node *m;
        advance(p);
        n = mknode(N_LOAD, t);
        expect(p, T_LPAREN);
        if (tok(p) != T_STRLIT)
            perr(p, cur(p)->line, cur(p)->col, "first operand of load statement must be a string literal");
        m = mknode(N_STRING, cur(p));
        m->s = advance(p)->s;
        n->a = m;
        while (tok(p) == T_COMMA) {
            Token *it;
            Node *kv;
            advance(p);
            if (tok(p) == T_RPAREN)
                break;
            it = cur(p);
            kv = mknode(N_KWARG, it);
            if (tok(p) == T_STRLIT) {
                Str *orig = advance(p)->s;
                kv->s = intern_n(orig->s, orig->len);
                kv->a = mknode(N_STRING, it);
                kv->a->s = orig;
                /* the name must be a valid identifier */
                {
                    int k, ok = orig->len > 0;
                    for (k = 0; k < orig->len; k++) {
                        char c = orig->s[k];
                        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' ||
                              (k > 0 && c >= '0' && c <= '9')))
                            ok = 0;
                    }
                    if (!ok)
                        perr(p, it->line, it->col, "load operand must be \"%s\" or ident=\"%s\" form",
                             orig->s, orig->s);
                }
            } else if (tok(p) == T_IDENT) {
                kv->s = advance(p)->s;
                expect(p, T_EQ);
                if (tok(p) != T_STRLIT)
                    perr(p, cur(p)->line, cur(p)->col, "load operand must be \"name\" or ident=\"name\" form");
                kv->a = mknode(N_STRING, cur(p));
                kv->a->s = advance(p)->s;
            } else {
                perr(p, it->line, it->col, "load operand must be \"name\" or localname=\"name\" (got %s)", tokdesc(p));
            }
            push(&items, kv);
        }
        expect(p, T_RPAREN);
        if (items.n == 0)
            perr(p, t->line, t->col, "load statement must import at least 1 symbol");
        n->list = items.v;
        n->n = items.n;
        push(out, n);
        return;
    }
    }
    /* expression, assignment, or augmented assignment */
    {
        Node *x = parse_expr(p, 0);
        int op = tok(p);
        if (op == T_EQ) {
            Token *et = advance(p);
            if (!valid_target(x, 0))
                perr(p, x->line, x->col, "can't assign to %s",
                     x->kind == N_CALL ? "function call" :
                     x->kind == N_INT || x->kind == N_STRING ? "literal" : "expression");
            n = mknode(N_ASSIGN, et);
            n->a = x;
            n->b = parse_expr(p, 0);
            push(out, n);
            return;
        }
        if (op >= T_PLUS_EQ && op <= T_GTGT_EQ) {
            Token *et = advance(p);
            if (!valid_target(x, 1))
                perr(p, x->line, x->col, "can't use %s as augmented assignment target",
                     x->kind == N_TUPLE ? "tuple expression" : x->kind == N_LIST ? "list expression" : "expression");
            n = mknode(N_AUGASSIGN, et);
            switch (op) {
            case T_PLUS_EQ: n->op = T_PLUS; break;
            case T_MINUS_EQ: n->op = T_MINUS; break;
            case T_STAR_EQ: n->op = T_STAR; break;
            case T_SLASH_EQ: n->op = T_SLASH; break;
            case T_SLASHSLASH_EQ: n->op = T_SLASHSLASH; break;
            case T_PERCENT_EQ: n->op = T_PERCENT; break;
            case T_AMP_EQ: n->op = T_AMP; break;
            case T_PIPE_EQ: n->op = T_PIPE; break;
            case T_CIRCUMFLEX_EQ: n->op = T_CIRCUMFLEX; break;
            case T_LTLT_EQ: n->op = T_LTLT; break;
            case T_GTGT_EQ: n->op = T_GTGT; break;
            }
            n->a = x;
            n->b = parse_expr(p, 0);
            push(out, n);
            return;
        }
        n = mknode(N_EXPRSTMT, t);
        n->a = x;
        push(out, n);
    }
}

static void parse_simple_stmt(Parser *p, NodeVec *out)
{
    for (;;) {
        parse_small_stmt(p, out);
        if (tok(p) != T_SEMI)
            break;
        advance(p);
        if (tok(p) == T_NEWLINE || tok(p) == T_EOF)
            break;
    }
    if (tok(p) == T_EOF)
        return;
    if (tok(p) != T_NEWLINE)
        perr(p, cur(p)->line, cur(p)->col, "got %s, want newline", tokdesc(p));
    advance(p);
}

static void parse_suite(Parser *p, NodeVec *out)
{
    if (tok(p) == T_NEWLINE) {
        advance(p);
        expect(p, T_INDENT);
        while (tok(p) != T_OUTDENT && tok(p) != T_EOF)
            parse_stmt(p, out);
        expect(p, T_OUTDENT);
        return;
    }
    parse_simple_stmt(p, out);
}

static Node *parse_if(Parser *p)
{
    Token *t = advance(p);      /* if or elif */
    Node *n = mknode(N_IF, t);
    NodeVec body = {0}, els = {0};
    n->a = parse_test(p);
    expect(p, T_COLON);
    parse_suite(p, &body);
    n->list = body.v;
    n->n = body.n;
    if (tok(p) == T_ELIF) {
        push(&els, parse_if(p));
    } else if (tok(p) == T_ELSE) {
        advance(p);
        expect(p, T_COLON);
        parse_suite(p, &els);
    }
    n->list2 = els.v;
    n->n2 = els.n;
    return n;
}

static Node *parse_loop_vars(Parser *p, Token *t)
{
    NodeVec vars = {0};
    int trailing = 0;
    for (;;) {
        push(&vars, parse_primary_suffix(p));
        if (tok(p) != T_COMMA)
            break;
        advance(p);
        trailing = 1;
        if (tok(p) == T_IN)
            break;
        trailing = 0;
    }
    if (vars.n == 1 && !trailing)
        return vars.v[0];
    {
        Node *tup = mknode(N_TUPLE, t);
        tup->list = vars.v;
        tup->n = vars.n;
        return tup;
    }
}

static void parse_stmt(Parser *p, NodeVec *out)
{
    Token *t = cur(p);
    Node *n;
    NodeVec body = {0};
    switch (tok(p)) {
    case T_DEF: {
        FuncInfo *fi;
        advance(p);
        n = mknode(N_DEF, t);
        n->s = expect(p, T_IDENT)->s;
        expect(p, T_LPAREN);
        fi = parse_params(p, T_RPAREN);
        expect(p, T_RPAREN);
        expect(p, T_COLON);
        parse_suite(p, &body);
        fi->body = body.v;
        fi->nbody = body.n;
        fi->name = n->s;
        fi->line = t->line;
        fi->col = t->col;
        n->fn = fi;
        push(out, n);
        return;
    }
    case T_IF:
        push(out, parse_if(p));
        return;
    case T_FOR:
        advance(p);
        n = mknode(N_FOR, t);
        n->a = parse_loop_vars(p, t);
        expect(p, T_IN);
        n->b = parse_expr(p, 0);
        expect(p, T_COLON);
        parse_suite(p, &body);
        n->list = body.v;
        n->n = body.n;
        push(out, n);
        return;
    case T_WHILE:
        advance(p);
        n = mknode(N_WHILE, t);
        n->a = parse_test(p);
        expect(p, T_COLON);
        parse_suite(p, &body);
        n->list = body.v;
        n->n = body.n;
        push(out, n);
        return;
    }
    parse_simple_stmt(p, out);
}

Node *parse_file(const char *filename, const char *src, int len, ErrList *errs)
{
    Parser P, *p = &P;
    NodeVec stmts = {0};
    Node *file;
    memset(p, 0, sizeof P);
    p->file = filename;
    p->errs = errs;
    p->toks = lex(filename, src, len, &p->ntoks, errs);
    if (!p->toks)
        return NULL;
    if (setjmp(p->jb))
        return NULL;
    while (tok(p) != T_EOF) {
        if (tok(p) == T_NEWLINE) {
            advance(p);
            continue;
        }
        parse_stmt(p, &stmts);
    }
    file = arena_alloc(sizeof(Node));
    file->kind = N_PASS;
    file->list = stmts.v;
    file->n = stmts.n;
    return file;
}

Node *parse_expr_string(const char *filename, const char *src, int len, ErrList *errs)
{
    Parser P, *p = &P;
    Node *x;
    memset(p, 0, sizeof P);
    p->file = filename;
    p->errs = errs;
    p->toks = lex(filename, src, len, &p->ntoks, errs);
    if (!p->toks)
        return NULL;
    if (setjmp(p->jb))
        return NULL;
    while (tok(p) == T_NEWLINE)
        advance(p);
    x = parse_expr(p, 0);
    while (tok(p) == T_NEWLINE)
        advance(p);
    if (tok(p) != T_EOF)
        perr(p, cur(p)->line, cur(p)->col, "got %s after expression, want EOF", tokdesc(p));
    return x;
}
