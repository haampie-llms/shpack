/* SPDX-License-Identifier: MIT
 * resolve.c -- static name resolution (the spec's "Name resolution"):
 * every identifier becomes a local slot (possibly a cell captured by a
 * nested function), a free variable, a module global, a predeclared name,
 * or a universal builtin. Also enforces the dialect's static restrictions
 * (no top-level control flow, no global reassignment, no while). */

#include <stdio.h>
#include <string.h>
#include "star.h"

typedef struct Block {
    Str **names;
    int *idx;
    int n, cap;
    struct Block *up;
} Block;

typedef struct FnCtx {
    FuncInfo *fi;           /* NULL for the toplevel */
    struct FnCtx *parent;
    Block *block;           /* innermost block; the function block is outermost */
    int nlocals, loccap;
    Str **localnames;
    char *iscell;
    int nfree, freecap;
    FreeVar *free;
    int loops;
} FnCtx;

typedef struct Resolver {
    const char *file;
    ErrList *errs;
    FnCtx *fn;
    int ng, gcap;
    Str **gnames;
    Node **gfirst;          /* first binding site, for messages */
    char *gload;            /* bound by load() */
    int (*is_predeclared)(Str *);
} Resolver;

static void rerr(Resolver *r, int line, int col, const char *fmt, ...)
{
    va_list ap;
    char tmp[512];
    ErrList *e = r->errs;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    e->pos = arena_grow(e->pos, sizeof(Pos) * e->n, sizeof(Pos) * (e->n + 1));
    e->msg = arena_grow(e->msg, sizeof(char *) * e->n, sizeof(char *) * (e->n + 1));
    e->pos[e->n].file = r->file;
    e->pos[e->n].line = line;
    e->pos[e->n].col = col;
    e->msg[e->n] = arena_strdup(tmp);
    e->n++;
}

/* ------------------------------------------------------------- blocks -- */

static int block_find(Block *b, Str *name)
{
    int i;
    for (i = b->n - 1; i >= 0; i--)
        if (b->names[i] == name)
            return b->idx[i];
    return -1;
}

static int new_local(FnCtx *c, Str *name)
{
    if (c->nlocals == c->loccap) {
        int nc = c->loccap ? c->loccap * 2 : 8;
        c->localnames = arena_grow(c->localnames, sizeof(Str *) * c->loccap, sizeof(Str *) * nc);
        c->iscell = arena_grow(c->iscell, c->loccap, nc);
        c->loccap = nc;
    }
    c->localnames[c->nlocals] = name;
    c->iscell[c->nlocals] = 0;
    return c->nlocals++;
}

static int block_bind(FnCtx *c, Block *b, Str *name)
{
    int i = block_find(b, name);
    if (i >= 0)
        return i;
    if (b->n == b->cap) {
        int nc = b->cap ? b->cap * 2 : 8;
        b->names = arena_grow(b->names, sizeof(Str *) * b->cap, sizeof(Str *) * nc);
        b->idx = arena_grow(b->idx, sizeof(int) * b->cap, sizeof(int) * nc);
        b->cap = nc;
    }
    i = new_local(c, name);
    b->names[b->n] = name;
    b->idx[b->n] = i;
    b->n++;
    return i;
}

static void push_block(FnCtx *c)
{
    Block *b = arena_alloc(sizeof(Block));
    b->up = c->block;
    c->block = b;
}

static void pop_block(FnCtx *c)
{
    c->block = c->block->up;
}

/* ------------------------------------------------------------ globals -- */

static int global_find(Resolver *r, Str *name)
{
    int i;
    for (i = 0; i < r->ng; i++)
        if (r->gnames[i] == name)
            return i;
    return -1;
}

static void global_bind(Resolver *r, Str *name, Node *site, int is_load)
{
    int i = global_find(r, name);
    if (i >= 0) {
        if (opts.global_reassign)
            return;
        if (r->gload[i] || is_load) {
            rerr(r, site->line, site->col, "cannot reassign top-level %s declared at %s:%d:%d",
                 name->s, r->file, r->gfirst[i]->line, r->gfirst[i]->col);
        } else {
            rerr(r, site->line, site->col, "cannot reassign global %s declared at %s:%d:%d",
                 name->s, r->file, r->gfirst[i]->line, r->gfirst[i]->col);
        }
        return;
    }
    if (r->ng == r->gcap) {
        int nc = r->gcap ? r->gcap * 2 : 16;
        r->gnames = arena_grow(r->gnames, sizeof(Str *) * r->gcap, sizeof(Str *) * nc);
        r->gfirst = arena_grow(r->gfirst, sizeof(Node *) * r->gcap, sizeof(Node *) * nc);
        r->gload = arena_grow(r->gload, r->gcap, nc);
        r->gcap = nc;
    }
    r->gnames[r->ng] = name;
    r->gfirst[r->ng] = site;
    r->gload[r->ng] = (char)is_load;
    r->ng++;
}

/* ----------------------------------------------------- binding sweeps -- */

typedef void (*BindFn)(void *ctx, Str *name, Node *site);

static void bind_target(Node *t, BindFn fn, void *ctx)
{
    int i;
    switch (t->kind) {
    case N_IDENT:
        fn(ctx, t->s, t);
        break;
    case N_PAREN:
        bind_target(t->a, fn, ctx);
        break;
    case N_TUPLE: case N_LIST:
        for (i = 0; i < t->n; i++)
            bind_target(t->list[i], fn, ctx);
        break;
    }
}

/* Collect the names a statement list binds in its own function block. */
static void collect(Node **stmts, int n, BindFn fn, void *ctx)
{
    int i;
    for (i = 0; i < n; i++) {
        Node *s = stmts[i];
        switch (s->kind) {
        case N_ASSIGN:
            bind_target(s->a, fn, ctx);
            break;
        case N_AUGASSIGN:
            if (s->a->kind == N_IDENT || (s->a->kind == N_PAREN && s->a->a->kind == N_IDENT))
                bind_target(s->a, fn, ctx);
            break;
        case N_DEF:
            fn(ctx, s->s, s);
            break;
        case N_FOR:
            bind_target(s->a, fn, ctx);
            collect(s->list, s->n, fn, ctx);
            break;
        case N_WHILE:
            collect(s->list, s->n, fn, ctx);
            break;
        case N_IF:
            collect(s->list, s->n, fn, ctx);
            collect(s->list2, s->n2, fn, ctx);
            break;
        }
    }
}

static void bind_local_cb(void *ctx, Str *name, Node *site)
{
    FnCtx *c = ctx;
    (void)site;
    block_bind(c, c->block, name);
}

static void bind_global_cb(void *ctx, Str *name, Node *site)
{
    global_bind((Resolver *)ctx, name, site, 0);
}

/* ------------------------------------------------------------- lookup -- */

static int add_free(FnCtx *c, Str *name, int from_free, int idx)
{
    int i;
    for (i = 0; i < c->nfree; i++)
        if (c->free[i].from_free == from_free && c->free[i].idx == idx)
            return i;
    if (c->nfree == c->freecap) {
        int nc = c->freecap ? c->freecap * 2 : 4;
        c->free = arena_grow(c->free, sizeof(FreeVar) * c->freecap, sizeof(FreeVar) * nc);
        c->freecap = nc;
    }
    c->free[c->nfree].name = name;
    c->free[c->nfree].from_free = from_free;
    c->free[c->nfree].idx = idx;
    return c->nfree++;
}

static int lookup(Resolver *r, FnCtx *c, Str *name, int *index)
{
    Block *b;
    for (b = c->block; b; b = b->up) {
        int i = block_find(b, name);
        if (i >= 0) {
            *index = i;
            return S_LOCAL;
        }
    }
    if (c->parent) {
        int pi, s = lookup(r, c->parent, name, &pi);
        if (s == S_LOCAL) {
            c->parent->iscell[pi] = 1;
            *index = add_free(c, name, 0, pi);
            return S_FREE;
        }
        if (s == S_FREE) {
            *index = add_free(c, name, 1, pi);
            return S_FREE;
        }
        *index = pi;
        return s;
    }
    {
        int g = global_find(r, name);
        if (g >= 0) {
            *index = g;
            return S_GLOBAL;
        }
    }
    if (r->is_predeclared && r->is_predeclared(name)) {
        *index = -1;
        return S_PREDECLARED;
    }
    if (universe_has(name)) {
        *index = -1;
        return S_UNIVERSAL;
    }
    return S_UNRESOLVED;
}

static void use(Resolver *r, Node *id)
{
    int idx;
    int s = lookup(r, r->fn, id->s, &idx);
    if (s == S_UNRESOLVED) {
        rerr(r, id->line, id->col, "undefined: %s", id->s->s);
        return;
    }
    id->scope = s;
    id->index = idx;
}

/* ------------------------------------------------------------ walking -- */

static void expr(Resolver *r, Node *e);
static void stmts(Resolver *r, Node **s, int n, int toplevel);
static void function(Resolver *r, FuncInfo *fi, int line, int col);

static void assign_target(Resolver *r, Node *t)
{
    int i;
    switch (t->kind) {
    case N_IDENT:
        use(r, t);
        break;
    case N_PAREN:
        assign_target(r, t->a);
        break;
    case N_TUPLE: case N_LIST:
        for (i = 0; i < t->n; i++)
            assign_target(r, t->list[i]);
        break;
    case N_INDEX:
        expr(r, t->a);
        expr(r, t->b);
        break;
    case N_DOT:
        expr(r, t->a);
        break;
    }
}

static void comp_bind_cb(void *ctx, Str *name, Node *site)
{
    FnCtx *c = ctx;
    (void)site;
    /* comprehension variables always get fresh slots in the new block */
    if (block_find(c->block, name) < 0) {
        Block *b = c->block;
        if (b->n == b->cap) {
            int nc = b->cap ? b->cap * 2 : 8;
            b->names = arena_grow(b->names, sizeof(Str *) * b->cap, sizeof(Str *) * nc);
            b->idx = arena_grow(b->idx, sizeof(int) * b->cap, sizeof(int) * nc);
            b->cap = nc;
        }
        b->names[b->n] = name;
        b->idx[b->n] = new_local(c, name);
        b->n++;
    }
}

static void expr(Resolver *r, Node *e)
{
    int i;
    if (!e)
        return;
    switch (e->kind) {
    case N_IDENT:
        use(r, e);
        return;
    case N_INT: case N_STRING:
        return;
    case N_LIST: case N_TUPLE:
        for (i = 0; i < e->n; i++)
            expr(r, e->list[i]);
        return;
    case N_DICT:
        for (i = 0; i < e->n; i++) {
            expr(r, e->list[i]->a);
            expr(r, e->list[i]->b);
        }
        return;
    case N_ENTRY:
        expr(r, e->a);
        expr(r, e->b);
        return;
    case N_COMP: {
        Node *first = e->list[0];
        expr(r, first->b);
        push_block(r->fn);
        bind_target(first->a, comp_bind_cb, r->fn);
        assign_target(r, first->a);
        for (i = 1; i < e->n; i++) {
            Node *cl = e->list[i];
            if (cl->kind == N_IFCLAUSE) {
                expr(r, cl->a);
            } else {
                bind_target(cl->a, comp_bind_cb, r->fn);
                assign_target(r, cl->a);
                expr(r, cl->b);
            }
        }
        expr(r, e->a);
        pop_block(r->fn);
        return;
    }
    case N_UNARY:
        expr(r, e->a);
        return;
    case N_BINARY:
        expr(r, e->a);
        expr(r, e->b);
        return;
    case N_COND:
        expr(r, e->a);
        expr(r, e->b);
        expr(r, e->c);
        return;
    case N_LAMBDA:
        function(r, e->fn, e->line, e->col);
        return;
    case N_CALL:
        expr(r, e->a);
        for (i = 0; i < e->n; i++) {
            Node *a = e->list[i];
            if (a->kind == N_KWARG || a->kind == N_STARARG || a->kind == N_STARSTARARG)
                expr(r, a->a);
            else
                expr(r, a);
        }
        return;
    case N_DOT: case N_PAREN:
        expr(r, e->a);
        return;
    case N_INDEX:
        expr(r, e->a);
        expr(r, e->b);
        return;
    case N_SLICE:
        expr(r, e->a);
        expr(r, e->b);
        expr(r, e->c);
        expr(r, e->d);
        return;
    }
    fatal("resolve: unexpected expression kind %d", e->kind);
}

static void function(Resolver *r, FuncInfo *fi, int line, int col)
{
    FnCtx c;
    Block fb;
    int i;
    (void)line;
    (void)col;
    /* defaults are evaluated in the enclosing scope */
    for (i = 0; i < fi->nparams; i++)
        if (fi->params[i]->kind == N_PARAM && fi->params[i]->a)
            expr(r, fi->params[i]->a);

    memset(&c, 0, sizeof c);
    memset(&fb, 0, sizeof fb);
    c.fi = fi;
    c.parent = r->fn;
    c.block = &fb;
    /* parameters first, in declaration order: slots 0..nparams-1. The frame
     * setup in eval.c relies on this ordering (named positional, then
     * keyword-only, then *args, then **kwargs). */
    {
        Node **ordered = arena_alloc(sizeof(Node *) * (fi->nparams + 1));
        int k = 0;
        for (i = 0; i < fi->nparams; i++)
            if (fi->params[i]->kind == N_PARAM)
                ordered[k++] = fi->params[i];
        for (i = 0; i < fi->nparams; i++)
            if (fi->params[i]->kind == N_PARAM_STAR && fi->params[i]->s)
                ordered[k++] = fi->params[i];
        for (i = 0; i < fi->nparams; i++)
            if (fi->params[i]->kind == N_PARAM_STARSTAR)
                ordered[k++] = fi->params[i];
        fi->params = ordered;
        fi->nparams = k;
        for (i = 0; i < k; i++) {
            if (block_find(&fb, ordered[i]->s) >= 0)
                rerr(r, ordered[i]->line, ordered[i]->col, "duplicate parameter: %s", ordered[i]->s->s);
            else
                block_bind(&c, &fb, ordered[i]->s);
        }
    }
    r->fn = &c;
    if (fi->expr) {
        expr(r, fi->expr);
    } else {
        collect(fi->body, fi->nbody, bind_local_cb, &c);
        stmts(r, fi->body, fi->nbody, 0);
    }
    r->fn = c.parent;
    fi->nlocals = c.nlocals;
    fi->localnames = c.localnames;
    fi->iscell = c.iscell;
    fi->nfree = c.nfree;
    fi->free = c.free;
}

static void stmts(Resolver *r, Node **s, int n, int toplevel)
{
    int i, j;
    for (i = 0; i < n; i++) {
        Node *st = s[i];
        switch (st->kind) {
        case N_EXPRSTMT:
            expr(r, st->a);
            break;
        case N_ASSIGN:
            expr(r, st->b);
            assign_target(r, st->a);
            break;
        case N_AUGASSIGN:
            expr(r, st->b);
            assign_target(r, st->a);
            break;
        case N_DEF:
            function(r, st->fn, st->line, st->col);
            {
                Node id;
                memset(&id, 0, sizeof id);
                id.kind = N_IDENT;
                id.s = st->s;
                id.line = st->line;
                id.col = st->col;
                use(r, &id);
                st->scope = id.scope;
                st->index = id.index;
            }
            break;
        case N_IF:
            if (r->fn->fi == NULL && !opts.toplevel_control)
                rerr(r, st->line, st->col, "if statement not within a function");
            expr(r, st->a);
            stmts(r, st->list, st->n, 0);
            stmts(r, st->list2, st->n2, 0);
            break;
        case N_FOR:
            if (r->fn->fi == NULL && !opts.toplevel_control)
                rerr(r, st->line, st->col, "for loop not within a function");
            expr(r, st->b);
            assign_target(r, st->a);
            r->fn->loops++;
            stmts(r, st->list, st->n, 0);
            r->fn->loops--;
            break;
        case N_WHILE:
            if (!opts.while_loops)
                rerr(r, st->line, st->col, "this Starlark dialect does not support while loops");
            else if (r->fn->fi == NULL && !opts.toplevel_control)
                rerr(r, st->line, st->col, "while loop not within a function");
            expr(r, st->a);
            r->fn->loops++;
            stmts(r, st->list, st->n, 0);
            r->fn->loops--;
            break;
        case N_RETURN:
            if (r->fn->fi == NULL)
                rerr(r, st->line, st->col, "return statement not within a function");
            expr(r, st->a);
            break;
        case N_BREAK: case N_CONTINUE:
            if (r->fn->loops == 0)
                rerr(r, st->line, st->col, "%s not in a loop", st->kind == N_BREAK ? "break" : "continue");
            break;
        case N_PASS:
            break;
        case N_LOAD:
            if (r->fn->fi != NULL) {
                rerr(r, st->line, st->col, "load statement within a function");
                break;
            }
            if (!toplevel) {
                rerr(r, st->line, st->col, "load statement within a conditional");
                break;
            }
            for (j = 0; j < st->n; j++) {
                Node *kv = st->list[j];
                Node id;
                memset(&id, 0, sizeof id);
                id.kind = N_IDENT;
                id.s = kv->s;
                id.line = kv->line;
                id.col = kv->col;
                use(r, &id);
                kv->scope = id.scope;
                kv->index = id.index;
            }
            break;
        default:
            fatal("resolve: unexpected statement kind %d", st->kind);
        }
    }
}

/* Bind the file's globals in order of first appearance: loads, defs,
 * assignments, loop variables (when top-level control is allowed). */
static void collect_globals(Resolver *r, Node **s, int n)
{
    int i, j;
    for (i = 0; i < n; i++) {
        Node *st = s[i];
        if (st->kind == N_LOAD) {
            for (j = 0; j < st->n; j++)
                global_bind(r, st->list[j]->s, st->list[j], 1);
        } else if (st->kind == N_IF || st->kind == N_FOR || st->kind == N_WHILE) {
            Node one = *st;
            Node *arr[1];
            arr[0] = &one;
            if (st->kind == N_FOR)
                bind_target(st->a, bind_global_cb, r);
            collect_globals(r, st->list, st->n);
            if (st->kind == N_IF)
                collect_globals(r, st->list2, st->n2);
            (void)arr;
        } else {
            collect(&s[i], 1, bind_global_cb, r);
        }
    }
}

int resolve_file(Node *file, const char *filename, FuncInfo **toplevel,
                 Str ***globals, int *nglobals, char **exported,
                 int (*is_predeclared)(Str *), ErrList *errs)
{
    Resolver R, *r = &R;
    FnCtx top;
    Block tb;
    FuncInfo *fi;
    int i, nerr0 = errs->n;
    memset(r, 0, sizeof R);
    memset(&top, 0, sizeof top);
    memset(&tb, 0, sizeof tb);
    r->file = filename;
    r->errs = errs;
    r->is_predeclared = is_predeclared;
    top.block = NULL;
    r->fn = &top;
    collect_globals(r, file->list, file->n);
    stmts(r, file->list, file->n, 1);

    fi = arena_alloc(sizeof(FuncInfo));
    fi->name = intern("<toplevel>");
    fi->filename = filename;
    fi->body = file->list;
    fi->nbody = file->n;
    fi->nlocals = top.nlocals;
    fi->localnames = top.localnames;
    fi->iscell = top.iscell;
    *toplevel = fi;
    *globals = r->gnames;
    *nglobals = r->ng;
    *exported = arena_alloc(r->ng + 1);
    for (i = 0; i < r->ng; i++)
        (*exported)[i] = r->gload[i] && !opts.load_binds_globally ? 2 :
                         r->gnames[i]->s[0] != '_';
    (void)tb;
    return errs->n == nerr0;
}
