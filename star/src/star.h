/* SPDX-License-Identifier: MIT
 *
 * star -- a small Starlark interpreter for shpack recipes.
 *
 * Written in the C subset tcc 0.9.27 accepts (built statically against musl
 * early in the kaem chain), and equally with any host cc. One process
 * evaluates one thing and exits, so memory comes from a bump arena that is
 * never freed, and errors unwind with longjmp to the nearest catch point.
 *
 * The dialect is pinned in star/DIALECT.md: Starlark as specified by
 * bazelbuild/starlark, with int64 ints, byte strings, no floats, no sets, no
 * while loops and no recursion.
 */
#ifndef STAR_H
#define STAR_H

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <setjmp.h>

/* ---------------------------------------------------------------- memory -- */

void *arena_alloc(size_t n);             /* zeroed, never freed */
char *arena_strndup(const char *s, size_t n);
char *arena_strdup(const char *s);
void *arena_grow(void *old, size_t oldn, size_t newn);

/* growable byte buffer */
typedef struct Buf {
    char *p;
    size_t len, cap;
} Buf;
void buf_init(Buf *b);
void buf_putc(Buf *b, int c);
void buf_put(Buf *b, const char *s, size_t n);
void buf_puts(Buf *b, const char *s);
void buf_printf(Buf *b, const char *fmt, ...);
char *buf_cstr(Buf *b);                  /* NUL-terminates, returns b->p */

/* ---------------------------------------------------------------- values -- */

enum {
    T_NONE, T_BOOL, T_INT, T_STRING, T_LIST, T_TUPLE, T_DICT, T_RANGE,
    T_FUNCTION, T_BUILTIN, T_STRUCT, T_MODULE, T_CELL, T_STRVIEW
};

typedef struct Obj { int type; } Obj;
typedef Obj *V;

typedef struct Str {
    int type;
    int len;
    uint32_t hash;          /* 0 = not yet computed */
    char s[1];              /* NUL-terminated for convenience; may contain NULs */
} Str;

typedef struct Int { int type; int64_t v; } Int;
typedef struct Bool { int type; int v; } Bool;

typedef struct List {
    int type;
    int frozen;
    int itercount;          /* > 0 while being iterated: mutation is an error */
    int len, cap;
    V *items;
} List;

typedef struct Tuple {
    int type;
    int len;
    V items[1];
} Tuple;

typedef struct DEntry { V key, val; uint32_t hash; } DEntry;

typedef struct Dict {
    int type;
    int frozen;
    int itercount;
    int count;              /* live entries */
    int nents, entcap;      /* entries, including deleted (key == NULL) */
    DEntry *ents;
    int *index;             /* open addressing: entry index + 1, 0 = empty */
    int indexcap;
} Dict;

typedef struct Range { int type; int64_t start, stop, step; } Range;

typedef struct Cell { int type; V v; } Cell;

/* s.elems(), s.elem_ords(), s.codepoints(), s.codepoint_ords(): iterable
 * views, not lists, exactly as in starlark-go (no len, no indexing). */
typedef struct StrView { int type; Str *s; int ords, codepoints; } StrView;

struct Node;
struct FuncInfo;
struct Module;
struct Args;

typedef struct Function {
    int type;
    struct FuncInfo *info;
    struct Module *module;
    V *defaults;            /* one per parameter; NULL = required */
    Cell **free;            /* captured cells */
} Function;

typedef V (*BuiltinFn)(struct Args *a);

typedef struct Builtin {
    int type;
    const char *name;
    BuiltinFn fn;
    V recv;                 /* bound receiver for methods, else NULL */
    void *data;             /* host data */
} Builtin;

/* struct(...), also module(...), and host records (ctx, actions). Fields are
 * kept sorted by name, as starlark-go's starlarkstruct does, so repr and
 * dir() are canonical. */
typedef struct Struct {
    int type;
    const char *ctor;       /* "struct", "module", or a host type name */
    V label;                /* module name, host payload; not a field */
    int n;
    Str **names;
    V *vals;
    int frozen;             /* modules/structs are immutable; kept for symmetry */
} Struct;

/* A loaded .star file: its exported globals. */
typedef struct Module {
    int type;
    const char *name;       /* path as given to load() */
    const char *filename;
    int nglobals;
    Str **gnames;
    V *globals;
    char *exported;         /* per global: 1 if loadable by others */
    struct Node *file;
    struct FuncInfo *toplevel;
    int state;              /* 0 new, 1 executing, 2 done */
} Module;

extern V None, True, False;

V mk_int(int64_t v);
V mk_bool(int b);
V mk_str(const char *s, int len);
V mk_cstr(const char *s);
V mk_strf(const char *fmt, ...);
V mk_list(int cap);
V mk_tuple(int n);
V mk_dict(void);
V mk_range(int64_t start, int64_t stop, int64_t step);
V mk_builtin(const char *name, BuiltinFn fn, V recv);
V mk_struct(const char *ctor, int n, Str **names, V *vals);  /* sorts */

#define TYPE(o) (((Obj *)(o))->type)
#define AS_STR(o) ((Str *)(o))
#define AS_INT(o) (((Int *)(o))->v)
#define AS_LIST(o) ((List *)(o))
#define AS_TUPLE(o) ((Tuple *)(o))
#define AS_DICT(o) ((Dict *)(o))

const char *type_name(V v);
int truth(V v);
uint32_t hash_value(V v);                /* errors on unhashable */
int hashable(V v);
int equal(V a, V b);
int compare(V a, V b, int op);           /* op: T_LT etc; errors if unordered */
int cmp3(V a, V b);                      /* for sorting: <0, 0, >0 */
void repr_to(Buf *b, V v);
void str_to(Buf *b, V v);
V repr_value(V v);
V str_value(V v);

void list_append(V l, V x);
void list_check_mutable(V l, const char *what);
V dict_get(V d, V key);                  /* NULL if absent */
void dict_set(V d, V key, V val);
int dict_del(V d, V key, V *val_out);    /* 1 if removed */
void dict_check_mutable(V d, const char *what);
void freeze_value(V v);

/* Iteration over any iterable (list, tuple, dict keys, range). Strings are
 * not iterable, as in the spec. */
typedef struct Iter {
    V src;
    int i;
    int64_t r;              /* range cursor */
    V list;                 /* materialized string view */
} Iter;
int iterable(V v);
void iter_start(Iter *it, V v);          /* errors if not iterable */
V iter_next(Iter *it);                   /* NULL at end */
void iter_done(Iter *it);
extern int iter_sp;
void iter_unwind(int sp);
V to_list(V v);                          /* fresh list of the elements */
int seq_len(V v);                        /* -1 if no len */

/* ----------------------------------------------------------------- lexer -- */

enum {
    T_EOF = 100, T_NEWLINE, T_INDENT, T_OUTDENT,
    T_IDENT, T_INTLIT, T_STRLIT,
    /* punctuation */
    T_PLUS, T_MINUS, T_STAR, T_SLASH, T_SLASHSLASH, T_PERCENT, T_STARSTAR,
    T_AMP, T_PIPE, T_CIRCUMFLEX, T_TILDE, T_LTLT, T_GTGT,
    T_DOT, T_COMMA, T_EQ, T_SEMI, T_COLON,
    T_LPAREN, T_RPAREN, T_LBRACK, T_RBRACK, T_LBRACE, T_RBRACE,
    T_LT, T_GT, T_GE, T_LE, T_EQL, T_NEQ,
    T_PLUS_EQ, T_MINUS_EQ, T_STAR_EQ, T_SLASH_EQ, T_SLASHSLASH_EQ,
    T_PERCENT_EQ, T_AMP_EQ, T_PIPE_EQ, T_CIRCUMFLEX_EQ, T_LTLT_EQ, T_GTGT_EQ,
    /* keywords */
    T_AND, T_BREAK, T_CONTINUE, T_DEF, T_ELIF, T_ELSE, T_FOR, T_IF, T_IN,
    T_LAMBDA, T_LOAD, T_NOT, T_NOT_IN, T_OR, T_PASS, T_RETURN, T_WHILE
};

const char *token_str(int tok);

/* -------------------------------------------------------------------- AST -- */

enum {
    /* expressions */
    N_IDENT, N_INT, N_STRING, N_LIST, N_TUPLE, N_DICT, N_ENTRY,
    N_COMP,         /* list or dict comprehension: a = body (N_ENTRY for dict),
                       list = clauses; op = T_LBRACK or T_LBRACE */
    N_FORCLAUSE,    /* a = vars, b = iterable */
    N_IFCLAUSE,     /* a = cond */
    N_UNARY,        /* op, a */
    N_BINARY,       /* op, a, b */
    N_COND,         /* a if b else c: a = then, b = cond, c = else */
    N_LAMBDA,       /* fn */
    N_CALL,         /* a = fn, list = args */
    N_KWARG,        /* name = s, a = value (call arg) */
    N_STARARG,      /* *a */
    N_STARSTARARG,  /* **a */
    N_DOT,          /* a . s */
    N_INDEX,        /* a [ b ] */
    N_SLICE,        /* a [ b : c : d ] -> b, c, list[0] = step (or NULL) */
    N_PAREN,        /* ( a ) -- kept so (a) += 1 resolves like Go */
    /* statements */
    N_EXPRSTMT, N_ASSIGN, N_AUGASSIGN, N_DEF, N_IF, N_FOR, N_WHILE,
    N_RETURN, N_BREAK, N_CONTINUE, N_PASS, N_LOAD,
    /* parameters (in FuncInfo) */
    N_PARAM,        /* s = name, a = default or NULL */
    N_PARAM_STAR,   /* * or *args (s may be NULL) */
    N_PARAM_STARSTAR
};

/* identifier binding scopes, filled in by the resolver */
enum { S_UNRESOLVED, S_LOCAL, S_FREE, S_GLOBAL, S_PREDECLARED, S_UNIVERSAL };

typedef struct Node {
    int kind;
    int line, col;
    int op;
    struct Node *a, *b, *c, *d;
    struct Node **list;
    int n;
    struct Node **list2;        /* else branch / elif chain */
    int n2;
    Str *s;                     /* identifier name, string literal */
    int64_t ival;
    int scope, index;           /* resolved identifier */
    struct FuncInfo *fn;        /* N_DEF, N_LAMBDA */
} Node;

typedef struct FreeVar {
    Str *name;
    int from_free;              /* 1: enclosing function's free[idx]; 0: its local cell */
    int idx;
} FreeVar;

typedef struct FuncInfo {
    Str *name;
    const char *filename;
    int line, col;
    Node **params;
    int nparams;                /* named params, then the *args and **kwargs ones */
    int npositional;            /* named positional params (before * / *args) */
    int nkwonly;                /* named params after * or *args */
    int has_varargs, has_kwargs;
    int nlocals;
    Str **localnames;
    char *iscell;               /* per local */
    int nfree;
    FreeVar *free;
    Node **body;
    int nbody;
    Node *expr;                 /* lambda body */
    int recursing;              /* active on the call stack */
} FuncInfo;

/* ------------------------------------------------------------- positions -- */

typedef struct Pos { const char *file; int line, col; } Pos;

/* --------------------------------------------------------------- options -- */

typedef struct Options {
    int toplevel_control;       /* if/for at top level */
    int global_reassign;
    int recursion;
    int while_loops;
    int load_binds_globally;
} Options;
extern Options opts;

/* --------------------------------------------------------------- parsing -- */

typedef struct ErrList {
    int n;
    Pos *pos;
    char **msg;
} ErrList;

Node *parse_file(const char *filename, const char *src, int len, ErrList *errs);
Node *parse_expr_string(const char *filename, const char *src, int len, ErrList *errs);
int resolve_file(Node *file, const char *filename, FuncInfo **toplevel,
                 Str ***globals, int *nglobals, char **exported,
                 int (*is_predeclared)(Str *), ErrList *errs);

/* ------------------------------------------------------------ evaluation -- */

typedef struct Frame {
    struct Frame *parent;
    FuncInfo *info;
    Function *fn;               /* NULL at toplevel */
    Module *module;
    V *locals;
    Cell **free;
    int line, col;              /* current position */
    const char *builtin;        /* name, when this is a builtin's frame */
} Frame;

typedef struct Args {
    int npos;
    V *pos;
    int nkw;
    Str **kwnames;
    V *kwvals;
    V self;                     /* receiver for bound methods */
    const char *name;           /* builtin name for messages */
    Builtin *builtin;
} Args;

/* error handling */
typedef struct Catch {
    jmp_buf jb;
    struct Catch *prev;
    Frame *frame;
    int depth;
} Catch;

extern Catch *catch_top;
extern Frame *cur_frame;
extern int call_depth;
extern char *err_msg;           /* message of the last error */
extern char *err_trace;         /* rendered traceback of the last error */
extern Pos err_pos;             /* position of the outermost frame */
extern Pos err_stack[64];       /* frame positions, innermost first */
extern int err_nstack;

void star_error(const char *fmt, ...);   /* no return */
void star_verror(const char *fmt, va_list ap);
void fatal(const char *fmt, ...);        /* internal error, exits */

V call_value(V fn, Args *a);
V call_simple(V fn, int n, V *argv);     /* positional-only convenience */
Module *compile_module(const char *name, const char *filename, const char *src, int len,
                       ErrList *errs);        /* NULL on static errors */
void exec_module(Module *m);             /* runs toplevel, then freezes globals */
void reset_modules(void);
int loaded_modules(Module ***out);
char *read_file_or_die(const char *path, int *len);
const char *did_you_mean(const char *name, V candidates);
Module *load_module(const char *name, const char *from_file);
V get_attr(V v, Str *name, int want_error);  /* NULL if absent and !want_error */
V index_value(V x, V i);
V binary_op(int op, V a, V b);
int value_in(V needle, V hay);

/* the loader hook: maps a load() string to a filename (host-provided) */
extern char *(*module_path_hook)(const char *name, const char *from_file);

/* Arg unpacking, Go-style: pairs of (const char *name, V *out), NULL-ended.
 * A name ending in '?' marks it and every following param optional. */
void unpack_args(Args *a, ...);
void unpack_positional(Args *a, int min, int max, ...);
void no_kwargs(Args *a);
int64_t want_int(V v, const char *what);
Str *want_str(V v, const char *what);

/* universe */
void universe_init(void);
V universe_lookup(Str *name);
int universe_has(Str *name);
V builtin_method(V recv, Str *name);    /* bound method or NULL */
void method_names(V recv, V list);      /* appends names for dir() */

/* predeclared, set by the host before evaluation */
extern Dict *predeclared;

/* strings */
Str *intern(const char *s);
Str *intern_n(const char *s, int n);
int str_eq(Str *a, const char *s);
V string_method(V recv, Str *name);
void string_methods(V list);
V string_format(Str *fmt, Args *a);      /* str.format */
V string_percent(Str *fmt, V arg);       /* fmt % arg */
int utf8_decode(const unsigned char *s, int n, int *cp);  /* bytes used, 0 if invalid */
int utf8_encode(char *out, int cp);

/* regex (test harness matches(), filter_file validation) */
int regex_match(const char *pattern, const char *s, int slen, char **err);

/* host */
void host_init(void);

/* safe int arithmetic */
int64_t add64(int64_t a, int64_t b);
int64_t sub64(int64_t a, int64_t b);
int64_t mul64(int64_t a, int64_t b);

#endif
