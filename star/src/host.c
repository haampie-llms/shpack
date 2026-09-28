/* SPDX-License-Identifier: MIT
 * host.c -- the shpack host API: recipe directives, the build context, the
 * action vocabulary, and the renderers.
 *
 *   star recipe --repo DIR --root DIR [--format shpack|json] [--out DIR] NAME
 *       Load DIR/NAME/package.star and print (or write into --out) its
 *       directive record: in the line formats lib/repo.sh has always written
 *       under $VAR/recipe/NAME/ (shpack), or as canonical JSON.
 *
 *   star plan --repo DIR --root DIR --ctx FILE [--format sh|json] NAME
 *       Evaluate the recipe's phases against the build context in FILE (a
 *       Starlark file assigning a dict to `ctx`) and print the resulting
 *       action lists: as a POSIX sh script for the shpack builder to source,
 *       or as canonical JSON.
 *
 * load("//x/y.star", ...) resolves against --root; any other load path is
 * relative to the loading file. See star/PROTOCOL.md for the contract.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "star.h"

#define STAR_VERSION "1.0"

static const char *opt_repo, *opt_root, *opt_ctx, *opt_out, *opt_format;

/* ------------------------------------------------------------ recipe record -- */

typedef struct Directive {
    const char *kind;       /* version resource depends_on patch build_system ... */
    Str *a;                 /* main operand: version, spec, file, name, dir */
    Str *sha256, *url, *fname;
    Str *when;              /* verbatim when= string, or NULL */
    const char *when_ver;   /* translated: exact version, or NULL */
    const char *when_arch;  /* translated: amd64/aarch64, or NULL */
    int64_t level;
    int flag;               /* parallel */
    int line;
} Directive;

static Directive *dirs;
static int ndirs, dircap;
static Str *pkg_description, *pkg_homepage, *pkg_license;
static int loading;         /* directives are callable only while loading */
static int package_called;

static Directive *new_directive(const char *kind)
{
    Directive *d;
    if (!loading)
        star_error("%s: directives may only be called while the recipe loads", kind);
    if (ndirs == dircap) {
        int nc = dircap ? dircap * 2 : 32;
        dirs = arena_grow(dirs, sizeof(Directive) * dircap, sizeof(Directive) * nc);
        dircap = nc;
    }
    d = &dirs[ndirs++];
    memset(d, 0, sizeof *d);
    d->kind = kind;
    d->level = 1;
    d->line = cur_frame && cur_frame->parent ? cur_frame->parent->line : 0;
    return d;
}

/* when= accepts a subset of Spack's spec syntax, space separated:
 *   @=VERSION        exactly this version of the package
 *   target=FAMILY:   amd64 is x86_64:, aarch64 is aarch64:
 * Returns 0 on success; *err is set otherwise. */
static int parse_when(Str *w, const char **ver, const char **arch, const char **err)
{
    const char *p = w->s, *end = w->s + w->len;
    *ver = *arch = NULL;
    *err = NULL;
    while (p < end) {
        const char *tok;
        int n;
        while (p < end && *p == ' ')
            p++;
        if (p >= end)
            break;
        tok = p;
        while (p < end && *p != ' ')
            p++;
        n = (int)(p - tok);
        if (n > 2 && tok[0] == '@' && tok[1] == '=') {
            if (*ver) {
                *err = "more than one @= constraint";
                return -1;
            }
            *ver = arena_strndup(tok + 2, n - 2);
        } else if (n == 14 && memcmp(tok, "target=x86_64:", 14) == 0) {
            *arch = "amd64";
        } else if (n == 15 && memcmp(tok, "target=aarch64:", 15) == 0) {
            *arch = "aarch64";
        } else if (n > 1 && tok[0] == '@') {
            *err = "use @=VERSION for an exact version (version ranges are not supported)";
            return -1;
        } else {
            *err = "only @=VERSION and target=x86_64: / target=aarch64: are supported";
            return -1;
        }
    }
    if (!*ver && !*arch) {
        *err = "empty constraint";
        return -1;
    }
    return 0;
}

static void set_when(Directive *d, V w, int allow_arch)
{
    const char *err;
    if (!w || w == None)
        return;
    d->when = want_str(w, d->kind);
    if (parse_when(d->when, &d->when_ver, &d->when_arch, &err) < 0)
        star_error("%s: when=\"%s\": %s", d->kind, d->when->s, err);
    if (d->when_arch && !allow_arch)
        star_error("%s: when=\"%s\": target= constraints are only supported on patch()", d->kind, d->when->s);
}

static Str *opt_str(V v, const char *what)
{
    if (!v || v == None)
        return NULL;
    return want_str(v, what);
}

static int valid_sha256(Str *s)
{
    int i;
    if (s->len != 64)
        return 0;
    for (i = 0; i < 64; i++) {
        char c = s->s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return 0;
    }
    return 1;
}

/* no spaces: every field lands in a space-separated state file line */
static void no_space(Str *s, const char *what)
{
    int i;
    for (i = 0; s && i < s->len; i++)
        if (s->s[i] == ' ' || s->s[i] == '\t' || s->s[i] == '\n' || s->s[i] == 0)
            star_error("%s: %s must not contain whitespace: \"%s\"", what, what, s->s);
}

static V d_package(Args *a)
{
    V desc = NULL, home = NULL, lic = NULL;
    unpack_args(a, "description?", &desc, "homepage?", &home, "license?", &lic, NULL);
    if (!loading)
        star_error("package: directives may only be called while the recipe loads");
    if (package_called++)
        star_error("package: called more than once");
    pkg_description = opt_str(desc, "package");
    pkg_homepage = opt_str(home, "package");
    pkg_license = opt_str(lic, "package");
    return None;
}

static V d_version(Args *a)
{
    V ver, sha = NULL, url = NULL, fname = NULL;
    Directive *d;
    unpack_args(a, "version", &ver, "sha256?", &sha, "url?", &url, "fname?", &fname, NULL);
    d = new_directive("version");
    d->a = want_str(ver, "version");
    d->sha256 = opt_str(sha, "version");
    d->url = opt_str(url, "version");
    d->fname = opt_str(fname, "version");
    no_space(d->a, "version");
    no_space(d->url, "url");
    no_space(d->fname, "fname");
    if (d->sha256 && !valid_sha256(d->sha256))
        star_error("version: sha256 must be 64 lowercase hex digits");
    if ((d->url || d->fname) && !d->sha256)
        star_error("version %s: a source needs sha256=", d->a->s);
    return None;
}

static V d_resource(Args *a)
{
    V url = NULL, sha = NULL, fname = NULL, when = NULL;
    Directive *d;
    unpack_args(a, "url?", &url, "sha256?", &sha, "fname?", &fname, "when?", &when, NULL);
    d = new_directive("resource");
    d->sha256 = opt_str(sha, "resource");
    d->url = opt_str(url, "resource");
    d->fname = opt_str(fname, "resource");
    no_space(d->url, "url");
    no_space(d->fname, "fname");
    if (!d->sha256 || !valid_sha256(d->sha256))
        star_error("resource: sha256= (64 lowercase hex digits) is required");
    if (!d->url && !d->fname)
        star_error("resource: url= or fname= is required");
    set_when(d, when, 0);
    return None;
}

static V d_depends_on(Args *a)
{
    V when = NULL;
    int i;
    for (i = 0; i < a->nkw; i++) {
        if (str_eq(a->kwnames[i], "when"))
            when = a->kwvals[i];
        else
            star_error("depends_on: unexpected keyword argument %s", a->kwnames[i]->s);
    }
    if (a->npos == 0)
        star_error("depends_on: at least one spec is required");
    for (i = 0; i < a->npos; i++) {
        Directive *d = new_directive("depends_on");
        d->a = want_str(a->pos[i], "depends_on");
        no_space(d->a, "spec");
        if (d->a->len == 0 || d->a->s[0] == '@')
            star_error("depends_on: invalid spec \"%s\"", d->a->s);
        set_when(d, when, 0);
    }
    return None;
}

static V d_patch(Args *a)
{
    V file, level = NULL, when = NULL;
    Directive *d;
    unpack_args(a, "file", &file, "level?", &level, "when?", &when, NULL);
    d = new_directive("patch");
    d->a = want_str(file, "patch");
    no_space(d->a, "file");
    if (level && level != None)
        d->level = want_int(level, "patch");
    set_when(d, when, 1);
    return None;
}

static V d_build_system(Args *a)
{
    V name, when = NULL;
    Directive *d;
    unpack_args(a, "name", &name, "when?", &when, NULL);
    d = new_directive("build_system");
    d->a = want_str(name, "build_system");
    no_space(d->a, "build_system");
    set_when(d, when, 0);
    return None;
}

static V d_parallel(Args *a)
{
    V b;
    Directive *d;
    unpack_positional(a, 1, 1, &b);
    if (TYPE(b) != T_BOOL)
        star_error("parallel: got %s, want bool", type_name(b));
    d = new_directive("parallel");
    d->flag = truth(b);
    return None;
}

static V d_build_directory(Args *a)
{
    V dir;
    Directive *d;
    unpack_positional(a, 1, 1, &dir);
    d = new_directive("build_directory");
    d->a = want_str(dir, "build_directory");
    no_space(d->a, "build_directory");
    if (d->a->len == 0 || d->a->s[0] == '/')
        star_error("build_directory: want a relative path");
    return None;
}

/* ------------------------------------------------------------------ actions -- */

/* An action is a struct with ctor "action" and an "op" field. */
static V mk_action(const char *op, int n, const char **names, V *vals)
{
    Str **nm = arena_alloc(sizeof(Str *) * (n + 1));
    V *vv = arena_alloc(sizeof(V) * (n + 1));
    int i, k = 0;
    nm[k] = intern("op");
    vv[k++] = mk_cstr(op);
    for (i = 0; i < n; i++) {
        if (!vals[i] || vals[i] == None)
            continue;
        nm[k] = intern(names[i]);
        vv[k++] = vals[i];
    }
    return mk_struct("action", k, nm, vv);
}

static V field(V action, const char *name)
{
    Struct *s = (Struct *)action;
    int i;
    for (i = 0; i < s->n; i++)
        if (str_eq(s->names[i], name))
            return s->vals[i];
    return NULL;
}

/* strings and (nested one level) lists/tuples of strings -> tuple of strings */
static void flatten_into(V out, V x, const char *what, int depth)
{
    if (TYPE(x) == T_STRING) {
        list_append(out, x);
        return;
    }
    if ((TYPE(x) == T_LIST || TYPE(x) == T_TUPLE) && depth < 2) {
        V l = to_list(x);
        int i;
        for (i = 0; i < AS_LIST(l)->len; i++)
            flatten_into(out, AS_LIST(l)->items[i], what, depth + 1);
        return;
    }
    star_error("%s: got %s, want string or list of strings", what, type_name(x));
}

static V strings_tuple(V list)
{
    V t = mk_tuple(AS_LIST(list)->len);
    memcpy(AS_TUPLE(t)->items, AS_LIST(list)->items, sizeof(V) * AS_LIST(list)->len);
    return t;
}

static V paths_arg(V x, const char *what)
{
    V l = mk_list(0);
    flatten_into(l, x, what, 0);
    if (AS_LIST(l)->len == 0)
        star_error("%s: no paths given", what);
    return strings_tuple(l);
}

static void want_env_name(Str *s, const char *what)
{
    int i, ok = s->len > 0;
    for (i = 0; i < s->len; i++) {
        char c = s->s[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || (i && c >= '0' && c <= '9')))
            ok = 0;
    }
    if (!ok)
        star_error("%s: invalid environment variable name \"%s\"", what, s->s);
}

static V a_run(Args *a)
{
    V argv = mk_list(0), cwd = NULL, env = NULL, out = NULL;
    const char *names[] = {"argv", "cwd", "env", "stdout"};
    V vals[4];
    int i;
    for (i = 0; i < a->nkw; i++) {
        Str *k = a->kwnames[i];
        if (str_eq(k, "cwd")) cwd = a->kwvals[i];
        else if (str_eq(k, "env")) env = a->kwvals[i];
        else if (str_eq(k, "stdout")) out = a->kwvals[i];
        else star_error("run: unexpected keyword argument %s", k->s);
    }
    for (i = 0; i < a->npos; i++)
        flatten_into(argv, a->pos[i], "run", 0);
    if (AS_LIST(argv)->len == 0)
        star_error("run: empty command");
    if (cwd && cwd != None)
        want_str(cwd, "run: cwd");
    if (out && out != None)
        want_str(out, "run: stdout");
    if (env && env != None) {
        Dict *d;
        if (TYPE(env) != T_DICT)
            star_error("run: env: got %s, want dict", type_name(env));
        d = AS_DICT(env);
        for (i = 0; i < d->nents; i++) {
            if (!d->ents[i].key)
                continue;
            want_env_name(want_str(d->ents[i].key, "run: env"), "run");
            want_str(d->ents[i].val, "run: env value");
        }
    }
    vals[0] = strings_tuple(argv);
    vals[1] = cwd;
    vals[2] = env;
    vals[3] = out;
    return mk_action("run", 4, names, vals);
}

static V a_sh(Args *a)
{
    V script, cwd = NULL;
    const char *names[] = {"script", "cwd"};
    V vals[2];
    unpack_args(a, "script", &script, "cwd?", &cwd, NULL);
    vals[0] = (V)want_str(script, "sh");
    vals[1] = cwd && cwd != None ? (V)want_str(cwd, "sh: cwd") : NULL;
    return mk_action("sh", 2, names, vals);
}

static V a_env(Args *a, const char *op)
{
    V name, value = NULL;
    const char *names[] = {"name", "value"};
    V vals[2];
    if (strcmp(op, "unsetenv") == 0)
        unpack_positional(a, 1, 1, &name);
    else
        unpack_positional(a, 2, 2, &name, &value);
    want_env_name(want_str(name, op), op);
    vals[0] = name;
    vals[1] = value ? (V)want_str(value, op) : NULL;
    return mk_action(op, 2, names, vals);
}
static V a_setenv(Args *a) { return a_env(a, "setenv"); }
static V a_prepend_path(Args *a) { return a_env(a, "prepend_path"); }
static V a_unsetenv(Args *a) { return a_env(a, "unsetenv"); }

static V a_chdir(Args *a)
{
    V p;
    const char *names[] = {"path"};
    unpack_positional(a, 1, 1, &p);
    want_str(p, "chdir");
    return mk_action("chdir", 1, names, &p);
}

static V a_mkdir(Args *a)
{
    V p;
    const char *names[] = {"paths"};
    V vals[1];
    int i;
    V l = mk_list(0);
    no_kwargs(a);
    for (i = 0; i < a->npos; i++)
        flatten_into(l, a->pos[i], "mkdir", 0);
    if (AS_LIST(l)->len == 0)
        star_error("mkdir: no paths given");
    p = strings_tuple(l);
    vals[0] = p;
    return mk_action("mkdir", 1, names, vals);
}

/* copy(src, dst, recursive = False, preserve = False): preserve keeps modes,
 * times and symlinks (cp -a) and implies recursive. */
static V a_copy(Args *a)
{
    V src, dst, rec = NULL, pres = NULL;
    const char *names[] = {"src", "dst", "recursive", "preserve"};
    V vals[4];
    unpack_args(a, "src", &src, "dst", &dst, "recursive?", &rec, "preserve?", &pres, NULL);
    vals[0] = paths_arg(src, "copy");
    vals[1] = (V)want_str(dst, "copy");
    vals[2] = rec && truth(rec) ? True : NULL;
    vals[3] = pres && truth(pres) ? True : NULL;
    return mk_action("copy", 4, names, vals);
}

static V a_move(Args *a)
{
    V src, dst;
    const char *names[] = {"src", "dst"};
    V vals[2];
    unpack_args(a, "src", &src, "dst", &dst, NULL);
    vals[0] = paths_arg(src, "move");
    vals[1] = (V)want_str(dst, "move");
    return mk_action("move", 2, names, vals);
}

static V a_remove(Args *a)
{
    V p, rec = NULL;
    const char *names[] = {"paths", "recursive"};
    V vals[2];
    unpack_args(a, "paths", &p, "recursive?", &rec, NULL);
    vals[0] = paths_arg(p, "remove");
    vals[1] = rec && truth(rec) ? True : NULL;
    return mk_action("remove", 2, names, vals);
}

static V link_impl(Args *a, const char *op)
{
    V target, link, force = NULL, if_missing = NULL;
    const char *names[] = {"target", "link", "force", "if_missing"};
    V vals[4];
    unpack_args(a, "target", &target, "link", &link, "force?", &force, "if_missing?", &if_missing, NULL);
    vals[0] = (V)want_str(target, op);
    vals[1] = (V)want_str(link, op);
    vals[2] = force && truth(force) ? True : NULL;
    vals[3] = if_missing && truth(if_missing) ? True : NULL;
    if (vals[2] && vals[3])
        star_error("%s: force and if_missing are mutually exclusive", op);
    return mk_action(op, 4, names, vals);
}
static V a_symlink(Args *a) { return link_impl(a, "symlink"); }
static V a_hardlink(Args *a) { return link_impl(a, "hardlink"); }

/* symlink_each(targets, dir, prefix = "", if_missing = False,
 *              relative = False, exclude = None):
 * for every existing path among `targets` (paths or globs, expanded once,
 * before any link is made; missing ones are skipped), a symlink DIR/PREFIX<basename> pointing at it -- or at
 * just <basename> if relative (a link beside its target). Base names matching
 * the glob `exclude` are skipped. For linking in what a prefix turns out to
 * contain (glibc's kernel headers, binutils' triple-prefixed tools). */
static V a_symlink_each(Args *a)
{
    V targets, dir, prefix = NULL, if_missing = NULL, relative = NULL, exclude = NULL;
    const char *names[] = {"targets", "dir", "prefix", "if_missing", "relative", "exclude"};
    V vals[6];
    unpack_args(a, "targets", &targets, "dir", &dir, "prefix?", &prefix, "if_missing?", &if_missing,
                "relative?", &relative, "exclude?", &exclude, NULL);
    vals[0] = paths_arg(targets, "symlink_each");
    vals[1] = (V)want_str(dir, "symlink_each");
    vals[2] = prefix && prefix != None && AS_STR(want_str(prefix, "symlink_each"))->len ? prefix : NULL;
    if (vals[2] && strchr(AS_STR(prefix)->s, '/'))
        star_error("symlink_each: prefix must not contain /");
    vals[3] = if_missing && truth(if_missing) ? True : NULL;
    vals[4] = relative && truth(relative) ? True : NULL;
    vals[5] = exclude && exclude != None ? (V)want_str(exclude, "symlink_each") : NULL;
    if (vals[5] && (strchr(AS_STR(exclude)->s, '/') || strchr(AS_STR(exclude)->s, '\'') ||
                    strchr(AS_STR(exclude)->s, ' ')))
        star_error("symlink_each: exclude is a base-name glob (no /, quotes or spaces)");
    return mk_action("symlink_each", 6, names, vals);
}

static void want_mode(V m, const char *what)
{
    Str *s = want_str(m, what);
    int i;
    if (s->len < 3 || s->len > 4)
        star_error("%s: mode must be octal digits like \"755\", got \"%s\"", what, s->s);
    for (i = 0; i < s->len; i++)
        if (s->s[i] < '0' || s->s[i] > '7')
            star_error("%s: mode must be octal digits like \"755\", got \"%s\"", what, s->s);
}

static V a_chmod(Args *a)
{
    V mode, paths;
    const char *names[] = {"mode", "paths"};
    V vals[2];
    unpack_args(a, "mode", &mode, "paths", &paths, NULL);
    want_mode(mode, "chmod");
    vals[0] = mode;
    vals[1] = paths_arg(paths, "chmod");
    return mk_action("chmod", 2, names, vals);
}

static V file_impl(Args *a, const char *op)
{
    V path, content, mode = NULL;
    const char *names[] = {"path", "content", "mode"};
    V vals[3];
    unpack_args(a, "path", &path, "content", &content, "mode?", &mode, NULL);
    vals[0] = (V)want_str(path, op);
    vals[1] = (V)want_str(content, op);
    if (mode && mode != None) {
        if (strcmp(op, "append_file") == 0)
            star_error("append_file: unexpected keyword argument mode");
        want_mode(mode, op);
        vals[2] = mode;
    } else {
        vals[2] = NULL;
    }
    return mk_action(op, 3, names, vals);
}
static V a_write_file(Args *a) { return file_impl(a, "write_file"); }
static V a_append_file(Args *a) { return file_impl(a, "append_file"); }

/* The portable regex subset of filter_file(): literal characters, `.`, `*`
 * after an atom, `^` at the start, `$` at the end, bracket expressions, and
 * backslash-escaped metacharacters. Other metacharacters (+ ? ( ) { } |)
 * must be escaped: Python's re and POSIX BRE disagree about them. Returns
 * the equivalent POSIX BRE, or NULL with *err set. */
static char *portable_to_bre(Str *re, const char **err)
{
    Buf b;
    int i = 0, atom = 0;
    buf_init(&b);
    while (i < re->len) {
        char c = re->s[i];
        switch (c) {
        case '\\': {
            char e;
            if (i + 1 >= re->len) {
                *err = "trailing backslash";
                return NULL;
            }
            e = re->s[i + 1];
            if (strchr(".*[]^$\\", e)) {
                buf_putc(&b, '\\');
                buf_putc(&b, e);
            } else if (strchr("+?(){}|/", e)) {
                buf_putc(&b, e);     /* literal in BRE */
            } else {
                *err = "unsupported escape (only metacharacters may be escaped)";
                return NULL;
            }
            i += 2;
            atom = 1;
            continue;
        }
        case '^':
            if (i != 0) {
                *err = "^ is only supported at the start";
                return NULL;
            }
            buf_putc(&b, c);
            i++;
            atom = 0;
            continue;
        case '$':
            if (i != re->len - 1) {
                *err = "$ is only supported at the end";
                return NULL;
            }
            buf_putc(&b, c);
            i++;
            continue;
        case '*':
            if (!atom) {
                *err = "* must follow a character, . or [...]";
                return NULL;
            }
            buf_putc(&b, c);
            i++;
            atom = 0;
            continue;
        case '[': {
            int j = i + 1;
            if (j < re->len && re->s[j] == '^')
                j++;
            if (j < re->len && re->s[j] == ']')
                j++;
            while (j < re->len && re->s[j] != ']') {
                if (re->s[j] == '\\' || (re->s[j] == '[' && j + 1 < re->len &&
                                         (re->s[j + 1] == ':' || re->s[j + 1] == '=' || re->s[j + 1] == '.'))) {
                    *err = "backslashes and [: :] classes are not supported inside [...]";
                    return NULL;
                }
                j++;
            }
            if (j >= re->len) {
                *err = "missing ]";
                return NULL;
            }
            buf_put(&b, re->s + i, j - i + 1);
            i = j + 1;
            atom = 1;
            continue;
        }
        case '+': case '?': case '(': case ')': case '{': case '}': case '|':
            *err = "+ ? ( ) { } | must be escaped with a backslash (they are not portable)";
            return NULL;
        case '\n':
            *err = "newlines cannot be matched (matching is per line)";
            return NULL;
        }
        buf_putc(&b, c);
        i++;
        atom = 1;
    }
    return buf_cstr(&b);
}

static V a_substitute(Args *a)
{
    V files, old, new;
    const char *names[] = {"files", "old", "new"};
    V vals[3];
    unpack_args(a, "files", &files, "old", &old, "new", &new, NULL);
    vals[0] = paths_arg(files, "substitute");
    vals[1] = (V)want_str(old, "substitute");
    vals[2] = (V)want_str(new, "substitute");
    if (AS_STR(old)->len == 0)
        star_error("substitute: old must not be empty");
    if (memchr(AS_STR(old)->s, '\n', AS_STR(old)->len))
        star_error("substitute: old must not contain a newline (matching is per line)");
    return mk_action("substitute", 3, names, vals);
}

static V a_filter_file(Args *a)
{
    V files, re, repl;
    const char *names[] = {"files", "regex", "repl"};
    V vals[3];
    const char *err = NULL;
    unpack_args(a, "files", &files, "regex", &re, "repl", &repl, NULL);
    vals[0] = paths_arg(files, "filter_file");
    vals[1] = (V)want_str(re, "filter_file");
    vals[2] = (V)want_str(repl, "filter_file");
    if (AS_STR(re)->len == 0)
        star_error("filter_file: empty regex");
    if (!portable_to_bre(AS_STR(re), &err))
        star_error("filter_file: regex \"%s\": %s", AS_STR(re)->s, err);
    return mk_action("filter_file", 3, names, vals);
}

/* ---------------------------------------------------------------- predeclared -- */

static const struct { const char *name; BuiltinFn fn; } host_fns[] = {
    {"package", d_package}, {"version", d_version}, {"resource", d_resource},
    {"depends_on", d_depends_on}, {"patch", d_patch}, {"build_system", d_build_system},
    {"parallel", d_parallel}, {"build_directory", d_build_directory},
    {"run", a_run}, {"sh", a_sh}, {"setenv", a_setenv}, {"prepend_path", a_prepend_path},
    {"unsetenv", a_unsetenv}, {"chdir", a_chdir}, {"mkdir", a_mkdir}, {"copy", a_copy},
    {"move", a_move}, {"remove", a_remove}, {"symlink", a_symlink}, {"hardlink", a_hardlink},
    {"symlink_each", a_symlink_each},
    {"chmod", a_chmod}, {"write_file", a_write_file}, {"append_file", a_append_file},
    {"substitute", a_substitute}, {"filter_file", a_filter_file},
    {NULL, NULL}
};

void host_init(void)
{
    V pre = mk_dict();
    int i;
    for (i = 0; host_fns[i].name; i++)
        dict_set(pre, (V)intern(host_fns[i].name), mk_builtin(host_fns[i].name, host_fns[i].fn, NULL));
    predeclared = AS_DICT(pre);
}

/* ------------------------------------------------------------------ loading -- */

static char *root_path_hook(const char *name, const char *from_file)
{
    Buf b;
    const char *slash;
    buf_init(&b);
    if (!from_file)
        return arena_strdup(name);  /* the host's own loads: recipe, build systems */
    if (name[0] == '/' && name[1] == '/') {
        buf_puts(&b, opt_root);
        buf_putc(&b, '/');
        buf_puts(&b, name + 2);
        return buf_cstr(&b);
    }
    if (strstr(name, "..") || name[0] == '/')
        star_error("load: \"%s\": use //path (relative to the shpack root) or a path below the loading file", name);
    slash = strrchr(from_file, '/');
    if (slash)
        buf_put(&b, from_file, slash - from_file + 1);
    buf_puts(&b, name);
    return buf_cstr(&b);
}

static Module *recipe_module;
static const char *recipe_name;

static void load_recipe(const char *name)
{
    Buf path;
    struct stat st;
    Module *m;
    buf_init(&path);
    buf_printf(&path, "%s/%s/package.star", opt_repo, name);
    if (stat(buf_cstr(&path), &st) != 0)
        star_error("no recipe %s", path.p);
    recipe_name = name;
    loading = 1;
    m = load_module(path.p, NULL);
    loading = 0;
    recipe_module = m;
    if (!package_called)
        star_error("%s: package() was not called", path.p);
}

/* Load each build system the recipe names, so that it is validated here and
 * listed among the loads (and so hashed by the caller). */
static void load_build_systems(void)
{
    int i;
    for (i = 0; i < ndirs; i++) {
        if (strcmp(dirs[i].kind, "build_system") == 0) {
            Buf b;
            buf_init(&b);
            buf_printf(&b, "//build_systems/%s.star", dirs[i].a->s);
            load_module(root_path_hook(buf_cstr(&b), opt_root), NULL);
        }
    }
}

/* ---------------------------------------------------------------- emitters -- */

static FILE *open_out(const char *file)
{
    Buf b;
    FILE *f;
    if (!opt_out)
        return stdout;
    buf_init(&b);
    buf_printf(&b, "%s/%s", opt_out, file);
    f = fopen(buf_cstr(&b), "w");
    if (!f)
        star_error("cannot write %s", b.p);
    return f;
}

static void close_out(FILE *f)
{
    if (f != stdout)
        fclose(f);
}

static const char *dash(Str *s) { return s ? s->s : "-"; }

static const char *default_fname(Directive *d)
{
    const char *slash;
    if (d->fname)
        return d->fname->s;
    if (!d->url)
        return "-";
    slash = strrchr(d->url->s, '/');
    return slash ? slash + 1 : d->url->s;
}

/* module paths relative to the root, for the caller to hash */
static void loads_list(Buf *b, int json)
{
    Module **mods;
    int n = loaded_modules(&mods), i, rootlen = strlen(opt_root), first = 1;
    for (i = 0; i < n; i++) {
        const char *f = mods[i]->filename;
        const char *rel;
        if (strncmp(f, opt_root, rootlen) == 0 && f[rootlen] == '/')
            rel = f + rootlen + 1;
        else if (strncmp(f, opt_repo, strlen(opt_repo)) == 0)
            continue;       /* the recipe itself: hashed with its package dir */
        else
            rel = f;
        if (strncmp(f, opt_repo, strlen(opt_repo)) == 0 && f[strlen(opt_repo)] == '/')
            continue;
        if (json) {
            if (!first)
                buf_puts(b, ", ");
            repr_to(b, mk_cstr(rel));
        } else {
            buf_printf(b, "%s\n", rel);
        }
        first = 0;
    }
}

static void emit_shpack(void)
{
    FILE *f;
    int i;
    Buf b;
#define LINES(file, cond, ...) do { \
        int any_ = 0; \
        for (i = 0; i < ndirs; i++) { \
            Directive *d = &dirs[i]; \
            if (!(cond)) continue; \
            if (!any_) { f = open_out(file); any_ = 1; if (!opt_out) fprintf(f, "## %s\n", file); } \
            fprintf(f, __VA_ARGS__); \
        } \
        if (any_) close_out(f); \
    } while (0)

    if (pkg_description) {
        f = open_out("description");
        if (!opt_out) fputs("## description\n", f);
        fprintf(f, "%s\n", pkg_description->s);
        close_out(f);
    }
    if (pkg_homepage) {
        f = open_out("homepage");
        if (!opt_out) fputs("## homepage\n", f);
        fprintf(f, "%s\n", pkg_homepage->s);
        close_out(f);
    }
    if (pkg_license) {
        f = open_out("license");
        if (!opt_out) fputs("## license\n", f);
        fprintf(f, "%s\n", pkg_license->s);
        close_out(f);
    }
    LINES("versions", strcmp(d->kind, "version") == 0, "%s %s %s %s\n",
          d->a->s, dash(d->sha256), default_fname(d), dash(d->url));
    LINES("resources", strcmp(d->kind, "resource") == 0, "%s %s %s %s\n",
          d->when_ver ? d->when_ver : "-", d->sha256->s, default_fname(d), dash(d->url));
    LINES("deps", strcmp(d->kind, "depends_on") == 0, "%s %s\n",
          d->when_ver ? d->when_ver : "-", d->a->s);
    LINES("patches", strcmp(d->kind, "patch") == 0, "%s level=%lld%s%s%s%s\n",
          d->a->s, (long long)d->level,
          d->when_ver ? " when=" : "", d->when_ver ? d->when_ver : "",
          d->when_arch ? " arch=" : "", d->when_arch ? d->when_arch : "");
    LINES("build_system", strcmp(d->kind, "build_system") == 0, "%s %s\n",
          d->when_ver ? d->when_ver : "-", d->a->s);
    LINES("parallel", strcmp(d->kind, "parallel") == 0, "%s\n", d->flag ? "true" : "false");
    LINES("build_directory", strcmp(d->kind, "build_directory") == 0, "%s\n", d->a->s);
#undef LINES
    buf_init(&b);
    loads_list(&b, 0);
    f = open_out("loads");
    if (!opt_out) fputs("## loads\n", f);
    fwrite(b.p ? b.p : "", 1, b.len, f);
    close_out(f);
}

static void json_str(Buf *b, const char *s, int n)
{
    int i;
    buf_putc(b, '"');
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"': buf_puts(b, "\\\""); break;
        case '\\': buf_puts(b, "\\\\"); break;
        case '\n': buf_puts(b, "\\n"); break;
        case '\t': buf_puts(b, "\\t"); break;
        case '\r': buf_puts(b, "\\r"); break;
        default:
            if (c < 0x20 || c == 0x7f)
                buf_printf(b, "\\u%04x", c);
            else
                buf_putc(b, c);
        }
    }
    buf_putc(b, '"');
}

static void json_value(Buf *b, V v)
{
    int i;
    switch (TYPE(v)) {
    case T_NONE: buf_puts(b, "null"); return;
    case T_BOOL: buf_puts(b, truth(v) ? "true" : "false"); return;
    case T_INT: buf_printf(b, "%lld", (long long)AS_INT(v)); return;
    case T_STRING: json_str(b, AS_STR(v)->s, AS_STR(v)->len); return;
    case T_LIST: case T_TUPLE: {
        V l = to_list(v);
        buf_putc(b, '[');
        for (i = 0; i < AS_LIST(l)->len; i++) {
            if (i)
                buf_puts(b, ", ");
            json_value(b, AS_LIST(l)->items[i]);
        }
        buf_putc(b, ']');
        return;
    }
    case T_DICT: {
        Dict *d = AS_DICT(v);
        int first = 1;
        buf_putc(b, '{');
        for (i = 0; i < d->nents; i++) {
            if (!d->ents[i].key)
                continue;
            if (TYPE(d->ents[i].key) != T_STRING)
                star_error("json: dict keys must be strings");
            if (!first)
                buf_puts(b, ", ");
            first = 0;
            json_value(b, d->ents[i].key);
            buf_puts(b, ": ");
            json_value(b, d->ents[i].val);
        }
        buf_putc(b, '}');
        return;
    }
    case T_STRUCT: {
        Struct *s = (Struct *)v;
        buf_putc(b, '{');
        for (i = 0; i < s->n; i++) {
            if (i)
                buf_puts(b, ", ");
            json_str(b, s->names[i]->s, s->names[i]->len);
            buf_puts(b, ": ");
            json_value(b, s->vals[i]);
        }
        buf_putc(b, '}');
        return;
    }
    }
    star_error("json: cannot encode %s", type_name(v));
}

static void json_opt(Buf *b, const char *key, Str *s)
{
    buf_printf(b, ", \"%s\": ", key);
    if (s)
        json_str(b, s->s, s->len);
    else
        buf_puts(b, "null");
}

static void emit_json(void)
{
    Buf b;
    int i;
    buf_init(&b);
    buf_puts(&b, "{\"name\": ");
    json_str(&b, recipe_name, strlen(recipe_name));
    buf_puts(&b, ", \"package\": {\"description\": ");
    if (pkg_description) json_str(&b, pkg_description->s, pkg_description->len); else buf_puts(&b, "null");
    buf_puts(&b, ", \"homepage\": ");
    if (pkg_homepage) json_str(&b, pkg_homepage->s, pkg_homepage->len); else buf_puts(&b, "null");
    buf_puts(&b, ", \"license\": ");
    if (pkg_license) json_str(&b, pkg_license->s, pkg_license->len); else buf_puts(&b, "null");
    buf_puts(&b, "},\n \"directives\": [");
    for (i = 0; i < ndirs; i++) {
        Directive *d = &dirs[i];
        buf_puts(&b, i ? ",\n   " : "\n   ");
        buf_printf(&b, "{\"directive\": \"%s\"", d->kind);
        if (strcmp(d->kind, "version") == 0) {
            json_opt(&b, "version", d->a);
            json_opt(&b, "sha256", d->sha256);
            json_opt(&b, "url", d->url);
            buf_puts(&b, ", \"fname\": ");
            if (d->url || d->fname)
                json_str(&b, default_fname(d), strlen(default_fname(d)));
            else
                buf_puts(&b, "null");
        } else if (strcmp(d->kind, "resource") == 0) {
            json_opt(&b, "sha256", d->sha256);
            json_opt(&b, "url", d->url);
            buf_puts(&b, ", \"fname\": ");
            json_str(&b, default_fname(d), strlen(default_fname(d)));
        } else if (strcmp(d->kind, "depends_on") == 0) {
            json_opt(&b, "spec", d->a);
        } else if (strcmp(d->kind, "patch") == 0) {
            json_opt(&b, "file", d->a);
            buf_printf(&b, ", \"level\": %lld", (long long)d->level);
        } else if (strcmp(d->kind, "build_system") == 0) {
            json_opt(&b, "name", d->a);
        } else if (strcmp(d->kind, "parallel") == 0) {
            buf_printf(&b, ", \"value\": %s", d->flag ? "true" : "false");
        } else if (strcmp(d->kind, "build_directory") == 0) {
            json_opt(&b, "path", d->a);
        }
        if (strcmp(d->kind, "resource") == 0 || strcmp(d->kind, "depends_on") == 0 ||
            strcmp(d->kind, "patch") == 0 || strcmp(d->kind, "build_system") == 0)
            json_opt(&b, "when", d->when);
        buf_putc(&b, '}');
    }
    buf_puts(&b, "\n ],\n \"loads\": [");
    loads_list(&b, 1);
    buf_puts(&b, "]}\n");
    fwrite(b.p, 1, b.len, stdout);
}

/* -------------------------------------------------------------------- plan -- */

static Dict *ctx_dict;          /* the dict from --ctx */
static const char *ctx_version, *ctx_arch, *ctx_id;

static V ctx_get(const char *key, int required)
{
    V v = dict_get((V)ctx_dict, mk_cstr(key));
    if (!v && required)
        star_error("ctx file: missing key \"%s\"", key);
    return v;
}

static V c_dep(Args *a)
{
    V name, deps, p;
    Str *n;
    unpack_positional(a, 1, 1, &name);
    n = want_str(name, "dep");
    deps = ctx_get("deps", 1);
    p = dict_get(deps, (V)n);
    if (!p)
        star_error("dep: '%s' is not in the dependency closure of %s", n->s, ctx_id);
    {
        Str *names[1];
        V vals[1];
        names[0] = intern("prefix");
        vals[0] = p;
        return mk_struct("dep", 1, names, vals);
    }
}

static V c_satisfies(Args *a)
{
    V spec;
    const char *ver, *arch, *err;
    Str *s;
    unpack_positional(a, 1, 1, &spec);
    s = want_str(spec, "satisfies");
    if (parse_when(s, &ver, &arch, &err) < 0)
        star_error("satisfies: \"%s\": %s", s->s, err);
    if (ver && strcmp(ver, ctx_version) != 0)
        return False;
    if (arch && strcmp(arch, ctx_arch) != 0)
        return False;
    return True;
}

/* The ctx value phases receive: the --ctx fields, plus pkg (the recipe's
 * exported globals), build_directory, and the dep()/satisfies() methods. */
static V make_ctx(void)
{
    static const char *keys[] = {
        "name", "version", "id", "arch", "prefix", "sh", "stage_dir", "source_dir",
        "package_dir", "jobs", "makejobs", "file_prefix_map", "debug_prefix_map",
        "package_files", NULL
    };
    Str *names[32];
    V vals[32];
    int n = 0, i;
    for (i = 0; keys[i]; i++) {
        V v = ctx_get(keys[i], 1);
        names[n] = intern(keys[i]);
        vals[n++] = v;
    }
    ctx_version = want_str(ctx_get("version", 1), "ctx")->s;
    ctx_arch = want_str(ctx_get("arch", 1), "ctx")->s;
    ctx_id = want_str(ctx_get("id", 1), "ctx")->s;
    names[n] = intern("dep");
    vals[n++] = mk_builtin("dep", c_dep, NULL);
    names[n] = intern("satisfies");
    vals[n++] = mk_builtin("satisfies", c_satisfies, NULL);
    names[n] = intern("build_directory");
    vals[n] = None;
    for (i = 0; i < ndirs; i++)
        if (strcmp(dirs[i].kind, "build_directory") == 0)
            vals[n] = (V)dirs[i].a;
    n++;
    {
        Module *m = recipe_module;
        Str **pn = arena_alloc(sizeof(Str *) * (m->nglobals + 1));
        V *pv = arena_alloc(sizeof(V) * (m->nglobals + 1));
        int k = 0;
        for (i = 0; i < m->nglobals; i++) {
            if (m->exported[i] != 1 || !m->globals[i])
                continue;
            pn[k] = m->gnames[i];
            pv[k++] = m->globals[i];
        }
        names[n] = intern("pkg");
        vals[n++] = mk_struct("package", k, pn, pv);
    }
    {
        V c = mk_struct("ctx", n, names, vals);
        freeze_value(c);
        return c;
    }
}

static V recipe_global(const char *name)
{
    Module *m = recipe_module;
    int i;
    for (i = 0; i < m->nglobals; i++)
        if (str_eq(m->gnames[i], name) && m->globals[i])
            return m->globals[i];
    return NULL;
}

static V module_global(Module *m, const char *name)
{
    int i;
    for (i = 0; i < m->nglobals; i++)
        if (str_eq(m->gnames[i], name) && m->exported[i] == 1)
            return m->globals[i];
    return NULL;
}

static void check_actions(V list, const char *phase)
{
    int i;
    if (TYPE(list) != T_LIST && TYPE(list) != T_TUPLE)
        star_error("%s: phase must return a list of actions, got %s", phase, type_name(list));
    list = to_list(list);
    for (i = 0; i < AS_LIST(list)->len; i++) {
        V x = AS_LIST(list)->items[i];
        if (TYPE(x) != T_STRUCT || strcmp(((Struct *)x)->ctor, "action") != 0)
            star_error("%s: element %d is a %s, not an action", phase, i, type_name(x));
    }
}

typedef struct Phase { const char *name; V actions; } Phase;

static int plan(Phase **out)
{
    V ctx, phases, fn;
    Module *bs;
    const char *bsname = "generic";
    Phase *ph;
    int i, n = 0;
    Buf b;

    for (i = 0; i < ndirs; i++) {
        Directive *d = &dirs[i];
        if (strcmp(d->kind, "build_system") == 0 &&
            (!d->when_ver || strcmp(d->when_ver, want_str(ctx_get("version", 1), "ctx")->s) == 0)) {
            bsname = d->a->s;
            break;
        }
    }
    buf_init(&b);
    buf_printf(&b, "//build_systems/%s.star", bsname);
    bs = load_module(root_path_hook(buf_cstr(&b), opt_root), NULL);
    ctx = make_ctx();

    phases = module_global(bs, "phases");
    if (!phases || (TYPE(phases) != T_LIST && TYPE(phases) != T_TUPLE))
        star_error("%s: build system must export a list `phases`", bs->filename);
    phases = to_list(phases);
    ph = arena_alloc(sizeof(Phase) * (AS_LIST(phases)->len + 2));

    /* setup_build_environment first: environment actions only */
    fn = recipe_global("setup_build_environment");
    if (!fn)
        fn = module_global(bs, "setup_build_environment");
    if (fn) {
        V acts = call_simple(fn, 1, &ctx);
        check_actions(acts, "setup_build_environment");
        acts = to_list(acts);
        for (i = 0; i < AS_LIST(acts)->len; i++) {
            const char *op = AS_STR(field(AS_LIST(acts)->items[i], "op"))->s;
            if (strcmp(op, "setenv") && strcmp(op, "prepend_path") && strcmp(op, "unsetenv"))
                star_error("setup_build_environment: only setenv/prepend_path/unsetenv actions are allowed, got %s", op);
        }
        ph[n].name = "setup_build_environment";
        ph[n++].actions = acts;
    }
    for (i = 0; i < AS_LIST(phases)->len; i++) {
        Str *pname = want_str(AS_LIST(phases)->items[i], "phases");
        V acts;
        fn = recipe_global(pname->s);
        if (!fn)
            fn = module_global(bs, pname->s);
        if (!fn)
            star_error("%s: build system %s has no default for phase %s", recipe_name, bsname, pname->s);
        acts = call_simple(fn, 1, &ctx);
        check_actions(acts, pname->s);
        ph[n].name = pname->s;
        ph[n++].actions = to_list(acts);
    }
    *out = ph;
    return n;
}

/* ------------------------------------------------------------- sh renderer -- */

static int plain_word(const char *s, int n)
{
    int i;
    if (n == 0)
        return 0;
    for (i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              strchr("_@%+=:,./-", c)))
            return 0;
    }
    return 1;
}

static void sq(Buf *b, const char *s, int n)
{
    int i;
    if (plain_word(s, n)) {
        buf_put(b, s, n);
        return;
    }
    buf_putc(b, '\'');
    for (i = 0; i < n; i++) {
        if (s[i] == '\'')
            buf_puts(b, "'\\''");
        else
            buf_putc(b, s[i]);
    }
    buf_putc(b, '\'');
}

static void sqv(Buf *b, V s)
{
    sq(b, AS_STR(s)->s, AS_STR(s)->len);
}

/* A path that may contain glob characters: literal parts are quoted, * ? and
 * [...] stay live. dir/ ** /pat (recursive) becomes $(star_rglob dir pat). */
static void path_word(Buf *b, V pv)
{
    Str *p = AS_STR(pv);
    const char *s = p->s;
    int n = p->len, i, lit = 0;
    const char *dd = strstr(s, "**");
    if (dd) {
        const char *after = dd + 2;
        if (!(dd > s && dd[-1] == '/' && *after == '/') || strstr(after, "**") ||
            strchr(after + 1, '/'))
            star_error("path \"%s\": ** is only supported as DIR/**/PATTERN", s);
        buf_puts(b, "$(star_rglob ");
        sq(b, s, (int)(dd - 1 - s));
        buf_putc(b, ' ');
        sq(b, after + 1, (int)strlen(after + 1));
        buf_putc(b, ')');
        return;
    }
    if (!strpbrk(s, "*?[")) {
        sq(b, s, n);
        return;
    }
    for (i = 0; i <= n; i++) {
        if (i == n || s[i] == '*' || s[i] == '?' || s[i] == '[') {
            if (i > lit) {
                buf_putc(b, '\'');
                buf_put(b, s + lit, i - lit);
                buf_putc(b, '\'');
            }
            if (i == n)
                break;
            if (s[i] == '[') {
                const char *close = memchr(s + i + 1, ']', n - i - 1);
                int k;
                if (!close)
                    star_error("path \"%s\": unterminated [", s);
                for (k = i; s + k <= close; k++)
                    if (s[k] == '\'' || s[k] == ' ')
                        star_error("path \"%s\": quotes and spaces are not allowed in a glob class", s);
                buf_put(b, s + i, (int)(close - (s + i)) + 1);
                i = (int)(close - s);
            } else {
                buf_putc(b, s[i]);
            }
            lit = i + 1;
        }
    }
}

static void path_words(Buf *b, V tuple)
{
    int i;
    for (i = 0; i < AS_TUPLE(tuple)->len; i++) {
        buf_putc(b, ' ');
        path_word(b, AS_TUPLE(tuple)->items[i]);
    }
}

static char pick_delim(Str *a, Str *c)
{
    const char *cands = "|#,@%!~^;:";
    int i;
    for (i = 0; cands[i]; i++)
        if (!memchr(a->s, cands[i], a->len) && !memchr(c->s, cands[i], c->len))
            return cands[i];
    star_error("cannot find a sed delimiter for \"%s\"", a->s);
    return 0;
}

/* sed replacement text for a literal string */
static void sed_repl(Buf *b, Str *s, char delim)
{
    int i;
    for (i = 0; i < s->len; i++) {
        char c = s->s[i];
        if (c == '\\' || c == '&' || c == delim)
            buf_putc(b, '\\');
        if (c == '\n') {
            buf_puts(b, "\\\n");
            continue;
        }
        buf_putc(b, c);
    }
}

static void render_action(Buf *b, V act)
{
    const char *op = AS_STR(field(act, "op"))->s;
    V v;
    int i;
    if (strcmp(op, "run") == 0) {
        V argv = field(act, "argv"), cwd = field(act, "cwd"), env = field(act, "env"),
          out = field(act, "stdout");
        if (cwd) {
            buf_puts(b, "(cd ");
            sqv(b, cwd);
            buf_puts(b, " && ");
        }
        if (env) {
            Dict *d = AS_DICT(env);
            for (i = 0; i < d->nents; i++) {
                if (!d->ents[i].key)
                    continue;
                buf_put(b, AS_STR(d->ents[i].key)->s, AS_STR(d->ents[i].key)->len);
                buf_putc(b, '=');
                sqv(b, d->ents[i].val);
                buf_putc(b, ' ');
            }
        }
        /* `command`: the plan is sourced by the builder shell, whose own
         * functions must never shadow the program a recipe names */
        buf_puts(b, "command");
        for (i = 0; i < AS_TUPLE(argv)->len; i++) {
            buf_putc(b, ' ');
            sqv(b, AS_TUPLE(argv)->items[i]);
        }
        if (out) {
            buf_puts(b, " > ");
            sqv(b, out);
        }
        if (cwd)
            buf_putc(b, ')');
    } else if (strcmp(op, "sh") == 0) {
        V cwd = field(act, "cwd");
        if (cwd) {
            buf_puts(b, "(cd ");
            sqv(b, cwd);
            buf_puts(b, " && ");
        }
        buf_puts(b, "\"$sh\" -ec ");
        sqv(b, field(act, "script"));
        if (cwd)
            buf_putc(b, ')');
    } else if (strcmp(op, "setenv") == 0) {
        buf_printf(b, "export %s=", AS_STR(field(act, "name"))->s);
        sqv(b, field(act, "value"));
    } else if (strcmp(op, "prepend_path") == 0) {
        const char *n = AS_STR(field(act, "name"))->s;
        buf_printf(b, "export %s=", n);
        sqv(b, field(act, "value"));
        buf_printf(b, "\"${%s:+:$%s}\"", n, n);
    } else if (strcmp(op, "unsetenv") == 0) {
        buf_printf(b, "unset %s", AS_STR(field(act, "name"))->s);
    } else if (strcmp(op, "chdir") == 0) {
        buf_puts(b, "cd ");
        path_word(b, field(act, "path"));
    } else if (strcmp(op, "mkdir") == 0) {
        buf_puts(b, "mkdir -p");
        path_words(b, field(act, "paths"));
    } else if (strcmp(op, "copy") == 0) {
        buf_puts(b, field(act, "preserve") ? "cp -a" : field(act, "recursive") ? "cp -R" : "cp");
        path_words(b, field(act, "src"));
        buf_putc(b, ' ');
        path_word(b, field(act, "dst"));
    } else if (strcmp(op, "move") == 0) {
        buf_puts(b, "mv");
        path_words(b, field(act, "src"));
        buf_putc(b, ' ');
        path_word(b, field(act, "dst"));
    } else if (strcmp(op, "remove") == 0) {
        buf_puts(b, field(act, "recursive") ? "rm -rf" : "rm -f");
        path_words(b, field(act, "paths"));
    } else if (strcmp(op, "symlink") == 0 || strcmp(op, "hardlink") == 0) {
        V link = field(act, "link");
        const char *flag = strcmp(op, "symlink") == 0 ? (field(act, "force") ? "-sf" : "-s")
                                                       : (field(act, "force") ? "-f" : NULL);
        if (field(act, "if_missing")) {
            buf_puts(b, "[ -e ");
            sqv(b, link);
            buf_puts(b, " ] || [ -L ");
            sqv(b, link);
            buf_puts(b, " ] || ");
        }
        buf_puts(b, "ln");
        if (flag)
            buf_printf(b, " %s", flag);
        buf_putc(b, ' ');
        sqv(b, field(act, "target"));
        buf_putc(b, ' ');
        sqv(b, link);
    } else if (strcmp(op, "symlink_each") == 0) {
        V pfx = field(act, "prefix");
        buf_puts(b, "for star_f in");
        path_words(b, field(act, "targets"));
        buf_puts(b, "; do [ -e \"$star_f\" ] || [ -L \"$star_f\" ] || continue; ");
        if (field(act, "exclude")) {
            buf_puts(b, "case \"${star_f##*/}\" in ");
            path_word(b, field(act, "exclude"));
            buf_puts(b, ") continue ;; esac; ");
        }
        buf_puts(b, "star_l=");
        sqv(b, field(act, "dir"));
        buf_putc(b, '/');
        if (pfx)
            sqv(b, pfx);
        buf_puts(b, "\"${star_f##*/}\"; ");
        if (field(act, "if_missing"))
            buf_puts(b, "[ -e \"$star_l\" ] || [ -L \"$star_l\" ] || ");
        buf_puts(b, field(act, "relative") ? "ln -s \"${star_f##*/}\" \"$star_l\"; done"
                                            : "ln -s \"$star_f\" \"$star_l\"; done");
    } else if (strcmp(op, "chmod") == 0) {
        buf_printf(b, "chmod %s", AS_STR(field(act, "mode"))->s);
        path_words(b, field(act, "paths"));
    } else if (strcmp(op, "write_file") == 0 || strcmp(op, "append_file") == 0) {
        buf_puts(b, "printf '%s' ");
        sqv(b, field(act, "content"));
        buf_puts(b, strcmp(op, "write_file") == 0 ? " > " : " >> ");
        sqv(b, field(act, "path"));
        if ((v = field(act, "mode")) != NULL) {
            buf_printf(b, "\nchmod %s ", AS_STR(v)->s);
            sqv(b, field(act, "path"));
        }
    } else if (strcmp(op, "substitute") == 0 || strcmp(op, "filter_file") == 0) {
        int lit = strcmp(op, "substitute") == 0;
        Str *pat = AS_STR(field(act, lit ? "old" : "regex"));
        Str *rep = AS_STR(field(act, lit ? "new" : "repl"));
        char delim = pick_delim(pat, rep);
        Buf e;
        buf_init(&e);
        buf_printf(&e, "s%c", delim);
        if (lit) {
            for (i = 0; i < pat->len; i++) {
                char c = pat->s[i];
                if (strchr(".*[]^$\\", c) || c == delim)
                    buf_putc(&e, '\\');
                buf_putc(&e, c);
            }
        } else {
            const char *err;
            char *bre = portable_to_bre(pat, &err);
            for (i = 0; bre[i]; i++) {
                if (bre[i] == delim)
                    buf_putc(&e, '\\');
                buf_putc(&e, bre[i]);
            }
        }
        buf_putc(&e, delim);
        sed_repl(&e, rep, delim);
        buf_printf(&e, "%cg", delim);
        buf_puts(b, "star_sed ");
        sq(b, e.p, (int)e.len);
        path_words(b, field(act, "files"));
    } else {
        star_error("render: unknown action %s", op);
    }
    buf_putc(b, '\n');
}

static void render_sh(Phase *ph, int n)
{
    Buf b;
    int i, j;
    buf_init(&b);
    buf_printf(&b, "# Generated by star %s plan for %s. Do not edit.\n", STAR_VERSION, ctx_id);
    for (i = 0; i < n; i++) {
        if (strcmp(ph[i].name, "setup_build_environment") != 0)
            buf_printf(&b, "echo '==> %s: %s'\n", ctx_id, ph[i].name);
        for (j = 0; j < AS_LIST(ph[i].actions)->len; j++)
            render_action(&b, AS_LIST(ph[i].actions)->items[j]);
    }
    fwrite(b.p, 1, b.len, stdout);
}

static void render_json(Phase *ph, int n)
{
    Buf b;
    int i, j;
    buf_init(&b);
    buf_puts(&b, "{\"id\": ");
    json_str(&b, ctx_id, strlen(ctx_id));
    buf_puts(&b, ", \"phases\": [");
    for (i = 0; i < n; i++) {
        buf_puts(&b, i ? ",\n  " : "\n  ");
        buf_puts(&b, "{\"phase\": ");
        json_str(&b, ph[i].name, strlen(ph[i].name));
        buf_puts(&b, ", \"actions\": [");
        for (j = 0; j < AS_LIST(ph[i].actions)->len; j++) {
            buf_puts(&b, j ? ",\n    " : "\n    ");
            json_value(&b, AS_LIST(ph[i].actions)->items[j]);
        }
        buf_puts(&b, "]}");
    }
    buf_puts(&b, "\n]}\n");
    fwrite(b.p, 1, b.len, stdout);
}

/* ---------------------------------------------------------------------- CLI -- */

static void load_ctx(void)
{
    int len, i;
    char *src = read_file_or_die(opt_ctx, &len);
    ErrList errs;
    Module *m;
    V pre_saved = (V)predeclared;
    memset(&errs, 0, sizeof errs);
    predeclared = NULL;
    m = compile_module(opt_ctx, opt_ctx, src, len, &errs);
    if (!m) {
        for (i = 0; i < errs.n; i++)
            fprintf(stderr, "%s:%d:%d: %s\n", errs.pos[i].file, errs.pos[i].line,
                    errs.pos[i].col, errs.msg[i]);
        star_error("invalid ctx file %s", opt_ctx);
    }
    exec_module(m);
    predeclared = AS_DICT(pre_saved);
    for (i = 0; i < m->nglobals; i++)
        if (str_eq(m->gnames[i], "ctx") && m->globals[i] && TYPE(m->globals[i]) == T_DICT)
            ctx_dict = AS_DICT(m->globals[i]);
    if (!ctx_dict)
        star_error("%s: must assign a dict to ctx", opt_ctx);
    reset_modules();    /* the ctx file is not a recipe load */
}

int host_main(int argc, char **argv)
{
    const char *cmd = argv[0], *name = NULL;
    int i;
    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
#define OPT(flag, var) if (strcmp(a, flag) == 0 && i + 1 < argc) { var = argv[++i]; continue; }
        OPT("--repo", opt_repo);
        OPT("--root", opt_root);
        OPT("--ctx", opt_ctx);
        OPT("--out", opt_out);
        OPT("--format", opt_format);
#undef OPT
        if (a[0] == '-' || name) {
            fprintf(stderr, "star %s: unexpected argument %s\n", cmd, a);
            return 2;
        }
        name = a;
    }
    if (!name || !opt_repo || !opt_root) {
        fprintf(stderr, "star %s: --repo, --root and a package name are required\n", cmd);
        return 2;
    }
    module_path_hook = root_path_hook;
    host_init();
    if (strcmp(cmd, "recipe") == 0) {
        if (!opt_format)
            opt_format = "shpack";
        if (strcmp(opt_format, "shpack") && strcmp(opt_format, "json")) {
            fprintf(stderr, "star recipe: --format must be shpack or json\n");
            return 2;
        }
        load_recipe(name);
        load_build_systems();
        if (strcmp(opt_format, "json") == 0)
            emit_json();
        else
            emit_shpack();
        return 0;
    }
    /* plan */
    {
        Phase *ph;
        int n;
        if (!opt_ctx) {
            fprintf(stderr, "star plan: --ctx is required\n");
            return 2;
        }
        if (!opt_format)
            opt_format = "sh";
        if (strcmp(opt_format, "sh") && strcmp(opt_format, "json")) {
            fprintf(stderr, "star plan: --format must be sh or json\n");
            return 2;
        }
        load_ctx();
        load_recipe(name);
        n = plan(&ph);
        if (strcmp(opt_format, "json") == 0)
            render_json(ph, n);
        else
            render_sh(ph, n);
    }
    return 0;
}
