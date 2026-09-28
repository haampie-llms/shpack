/* SPDX-License-Identifier: MIT
 * main.c -- the star command line:
 *
 *   star run FILE                  execute a Starlark file
 *   star test [--xfail F] FILE...  starlark-go style chunked conformance tests
 *   star recipe ...                shpack: evaluate a package recipe (host.c)
 *   star plan ...                  shpack: render a package's build plan (host.c)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "star.h"

extern FILE *print_stream;
int host_main(int argc, char **argv);   /* host.c */

static void usage(void)
{
    fputs("usage: star version\n"
          "       star run FILE\n"
          "       star test [--xfail LIST] FILE...\n"
          "       star recipe --repo DIR --root DIR [--format shpack|json] [--out DIR] NAME\n"
          "       star plan --repo DIR --root DIR --ctx FILE [--format sh|json] NAME\n", stderr);
    exit(2);
}

/* Unwind interpreter state after an error was caught at frame `to`. */
void unwind_to(Frame *to, int depth, int isp)
{
    extern int eq_depth, repr_depth;
    Frame *f;
    eq_depth = repr_depth = 0;
    for (f = cur_frame; f && f != to; f = f->parent)
        if (f->fn)
            f->info->recursing--;
    cur_frame = to;
    call_depth = depth;
    iter_unwind(isp);
}

static char *module_path_rel(const char *name, const char *from_file)
{
    const char *slash = strrchr(from_file, '/');
    Buf b;
    if (name[0] == '/' || !slash)
        return arena_strdup(name);
    buf_init(&b);
    buf_put(&b, from_file, slash - from_file + 1);
    buf_puts(&b, name);
    return buf_cstr(&b);
}

static int cmd_run(int argc, char **argv)
{
    int len, i;
    char *src;
    ErrList errs;
    Module *m;
    if (argc < 1)
        usage();
    module_path_hook = module_path_rel;
    print_stream = stdout;
    src = read_file_or_die(argv[0], &len);
    memset(&errs, 0, sizeof errs);
    m = compile_module(argv[0], argv[0], src, len, &errs);
    if (!m) {
        for (i = 0; i < errs.n; i++)
            fprintf(stderr, "%s:%d:%d: %s\n", errs.pos[i].file, errs.pos[i].line,
                    errs.pos[i].col, errs.msg[i]);
        return 1;
    }
    exec_module(m);
    return 0;
}

/* ------------------------------------------------------ conformance tests -- */

static int failures;
static const char *test_file;
static int chunk_failed;

static void report(int line, const char *fmt, ...)
{
    va_list ap;
    fprintf(stdout, "%s:%d: ", test_file, line);
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    chunk_failed = 1;
}

static int outer_line(void)
{
    Frame *f;
    int line = 0;
    for (f = cur_frame; f; f = f->parent)
        if (f->info && strcmp(f->info->filename, test_file) == 0)
            line = f->line;
    return line;
}

static V t_error(Args *a)
{
    V msg;
    unpack_positional(a, 1, 1, &msg);
    report(outer_line(), "%s", TYPE(msg) == T_STRING ? AS_STR(msg)->s : AS_STR(str_value(msg))->s);
    return None;
}

static V t_catch(Args *a)
{
    V f;
    Catch c;
    int isp = iter_sp;
    unpack_positional(a, 1, 1, &f);
    c.prev = catch_top;
    c.frame = cur_frame;
    c.depth = call_depth;
    catch_top = &c;
    if (setjmp(c.jb) == 0) {
        call_simple(f, 0, NULL);
        catch_top = c.prev;
        return None;
    }
    catch_top = c.prev;
    unwind_to(c.frame, c.depth, isp);
    return mk_cstr(err_msg);
}

static V t_matches(Args *a)
{
    V pat, s;
    char *err = NULL;
    int r;
    unpack_args(a, "pattern", &pat, "str", &s, NULL);
    r = regex_match(want_str(pat, "matches")->s, want_str(s, "matches")->s, AS_STR(s)->len, &err);
    if (r < 0)
        star_error("matches: bad regexp %s: %s", AS_STR(pat)->s, err);
    return mk_bool(r);
}

static V t_module(Args *a)
{
    Str **names;
    V *vals;
    int i;
    if (a->npos != 1 || TYPE(a->pos[0]) != T_STRING)
        star_error("module: got %d arguments, want 1 string", a->npos);
    names = arena_alloc(sizeof(Str *) * (a->nkw + 1));
    vals = arena_alloc(sizeof(V) * (a->nkw + 1));
    for (i = 0; i < a->nkw; i++) {
        names[i] = a->kwnames[i];
        vals[i] = a->kwvals[i];
    }
    {
        V m = mk_struct("module", a->nkw, names, vals);
        ((Struct *)m)->label = a->pos[0];
        return m;
    }
}

static V t_freeze(Args *a)
{
    V x;
    unpack_positional(a, 1, 1, &x);
    freeze_value(x);
    return x;
}

static V t_unsupported(Args *a)
{
    star_error("%s: not supported by star", a->name);
    return NULL;
}

/* Go's strconv.Unquote for the ### "pattern" annotations */
static char *unquote(const char *s, int n)
{
    Buf b;
    int i;
    buf_init(&b);
    if (n >= 2 && s[0] == '`' && s[n - 1] == '`') {
        buf_put(&b, s + 1, n - 2);
        return buf_cstr(&b);
    }
    if (n < 2 || s[0] != '"' || s[n - 1] != '"')
        return NULL;
    for (i = 1; i < n - 1; i++) {
        if (s[i] != '\\') {
            buf_putc(&b, s[i]);
            continue;
        }
        i++;
        switch (s[i]) {
        case 'n': buf_putc(&b, '\n'); break;
        case 't': buf_putc(&b, '\t'); break;
        case '\\': buf_putc(&b, '\\'); break;
        case '"': buf_putc(&b, '"'); break;
        case '\'': buf_putc(&b, '\''); break;
        default: buf_putc(&b, '\\'); buf_putc(&b, s[i]); break;
        }
    }
    return buf_cstr(&b);
}

typedef struct Want { int line; char *pattern; int seen; } Want;

static void got_error(Want *w, int nw, int line, const char *msg)
{
    int i;
    for (i = 0; i < nw; i++) {
        if (w[i].line == line && !w[i].seen) {
            char *err = NULL;
            int r = regex_match(w[i].pattern, msg, strlen(msg), &err);
            w[i].seen = 1;
            if (r < 0)
                report(line, "bad pattern %s: %s", w[i].pattern, err);
            else if (r == 0)
                report(line, "error \"%s\" does not match pattern \"%s\"", msg, w[i].pattern);
            return;
        }
    }
    report(line, "unexpected error: %s", msg);
}

static int is_xfail(const char *list, const char *file, int line)
{
    char key[512];
    const char *base = strrchr(file, '/');
    base = base ? base + 1 : file;
    snprintf(key, sizeof key, "\n%s:%d ", base, line);
    return list && strstr(list, key) != NULL;
}

static void run_chunk(const char *file, const char *src, int len, int firstline)
{
    Buf b;
    Want *want = NULL;
    int nw = 0, i, line;
    const char *p, *end = src + len;
    ErrList errs;
    Module *m;
    Options saved = opts;
    Catch c;

    /* pad so line numbers match the file */
    buf_init(&b);
    for (i = 1; i < firstline; i++)
        buf_putc(&b, '\n');
    buf_put(&b, src, len);

    /* expected errors */
    for (p = src, line = firstline; p < end; line++) {
        const char *eol = memchr(p, '\n', end - p), *hash;
        int ll;
        if (!eol)
            eol = end;
        ll = (int)(eol - p);
        hash = NULL;
        for (i = 0; i + 2 < ll; i++)
            if (p[i] == '#' && p[i + 1] == '#' && p[i + 2] == '#') {
                hash = p + i + 3;
                break;
            }
        if (hash) {
            const char *q = hash, *qe = eol;
            char *pat;
            while (q < qe && (*q == ' ' || *q == '\t'))
                q++;
            while (qe > q && (qe[-1] == ' ' || qe[-1] == '\t' || qe[-1] == '\r'))
                qe--;
            pat = unquote(q, (int)(qe - q));
            if (!pat) {
                report(line, "not a quoted regexp: %.*s", (int)(qe - q), q);
            } else {
                want = arena_grow(want, sizeof(Want) * nw, sizeof(Want) * (nw + 1));
                want[nw].line = line;
                want[nw].pattern = pat;
                want[nw].seen = 0;
                nw++;
            }
        }
        p = eol + 1;
    }

    memset(&opts, 0, sizeof opts);
#define OPT(name, field) if (strstr(buf_cstr(&b), "option:" name)) opts.field = 1
    OPT("while", while_loops);
    OPT("toplevelcontrol", toplevel_control);
    OPT("globalreassign", global_reassign);
    OPT("loadbindsglobally", load_binds_globally);
    OPT("recursion", recursion);
#undef OPT

    memset(&errs, 0, sizeof errs);
    m = compile_module(file, file, b.p, (int)b.len, &errs);
    if (!m) {
        for (i = 0; i < errs.n; i++)
            got_error(want, nw, errs.pos[i].line, errs.msg[i]);
    } else {
        int isp = iter_sp;
        c.prev = catch_top;
        c.frame = cur_frame;
        c.depth = call_depth;
        catch_top = &c;
        if (setjmp(c.jb) == 0) {
            exec_module(m);
            catch_top = c.prev;
        } else {
            catch_top = c.prev;
            unwind_to(c.frame, c.depth, isp);
            int k;
            for (k = 0; k < err_nstack; k++)
                if (strcmp(err_stack[k].file, file) == 0)
                    break;
            if (k < err_nstack)
                got_error(want, nw, err_stack[k].line, err_msg);
            else
                report(firstline, "error outside test file: %s", err_trace);
        }
    }
    for (i = 0; i < nw; i++)
        if (!want[i].seen)
            report(want[i].line, "expected error matching \"%s\"", want[i].pattern);
    opts = saved;
}

static int cmd_test(int argc, char **argv)
{
    char *xfail = NULL;
    int i, nxfail = 0, nxpass = 0, nchunks = 0;
    V pre = mk_dict();
    if (argc >= 2 && strcmp(argv[0], "--xfail") == 0) {
        int len;
        char *s = read_file_or_die(argv[1], &len);
        Buf b;
        buf_init(&b);
        buf_putc(&b, '\n');
        buf_puts(&b, s);
        xfail = buf_cstr(&b);
        argc -= 2;
        argv += 2;
    }
    module_path_hook = module_path_rel;
    print_stream = stdout;
    dict_set(pre, (V)intern("error"), mk_builtin("error", t_error, NULL));
    dict_set(pre, (V)intern("catch"), mk_builtin("catch", t_catch, NULL));
    dict_set(pre, (V)intern("matches"), mk_builtin("matches", t_matches, NULL));
    dict_set(pre, (V)intern("module"), mk_builtin("module", t_module, NULL));
    dict_set(pre, (V)intern("_freeze"), mk_builtin("freeze", t_freeze, NULL));
    dict_set(pre, (V)intern("_floateq"), mk_builtin("_floateq", t_unsupported, NULL));
    dict_set(pre, (V)intern("hasfields"), mk_builtin("hasfields", t_unsupported, NULL));
    dict_set(pre, (V)intern("fibonacci"), mk_builtin("fibonacci", t_unsupported, NULL));
    predeclared = AS_DICT(pre);

    for (i = 0; i < argc; i++) {
        int len, line = 1;
        char *src = read_file_or_die(argv[i], &len);
        char *p = src, *end = src + len;
        test_file = argv[i];
        while (p <= end) {
            char *sep = NULL, *q;
            int chunklen, k;
            for (q = p; q + 5 <= end; q++)
                if (q[0] == '\n' && q[1] == '-' && q[2] == '-' && q[3] == '-' && q[4] == '\n') {
                    sep = q;
                    break;
                }
            chunklen = sep ? (int)(sep - p) + 1 : (int)(end - p);
            chunk_failed = 0;
            {
                int before = failures;
                (void)before;
                run_chunk(argv[i], p, chunklen, line);
            }
            nchunks++;
            if (is_xfail(xfail, argv[i], line)) {
                if (chunk_failed) {
                    nxfail++;
                } else {
                    printf("%s:%d: XPASS (chunk listed as expected failure)\n", argv[i], line);
                    nxpass++;
                }
            } else if (chunk_failed) {
                printf("%s:%d: FAIL (chunk starting here)\n", argv[i], line);
                failures++;
            }
            for (k = 0; k < chunklen; k++)
                if (p[k] == '\n')
                    line++;
            if (!sep)
                break;
            line++;                 /* the --- line */
            p = sep + 5;
        }
    }
    printf("star test: %d chunks, %d failed, %d expected failures, %d unexpected passes\n",
           nchunks, failures, nxfail, nxpass);
    return failures || nxpass ? 1 : 0;
}

int main(int argc, char **argv)
{
    universe_init();
    if (argc < 2)
        usage();
    if (strcmp(argv[1], "version") == 0) {
        puts("star 1.0");
        return 0;
    }
    if (strcmp(argv[1], "run") == 0)
        return cmd_run(argc - 2, argv + 2);
    if (strcmp(argv[1], "test") == 0)
        return cmd_test(argc - 2, argv + 2);
    if (strcmp(argv[1], "recipe") == 0 || strcmp(argv[1], "plan") == 0)
        return host_main(argc - 1, argv + 1);
    usage();
    return 2;
}
