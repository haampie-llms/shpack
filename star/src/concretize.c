/* SPDX-License-Identifier: MIT
 *
 * concretize.c -- the host of shpack's concretizer, which is Starlark
 * (shpack/lib/concretize.star). The module is pure: it gets the host's inputs
 * through a `host` struct and returns the state files to write.
 *
 *   star concretize --repo DIR --root DIR --module FILE --cfg CFG.star --out VAR SPEC...
 *
 * host.recipe(name)       the directive record of a recipe (None without one)
 * host.files(name)        [[path, sha256], ...] of the files in the package
 *                         directory: depth first, names sorted bytewise,
 *                         dotfiles and dangling symlinks skipped
 * host.sha256(s)          the hex digest of a string
 * host.sha256_file(path)  ... of a file
 * host.read(path)         a file's content, None if it does not exist
 * host.star_version       "star 1.0"
 *
 * concretize(host, cfg, specs) returns {"files": {path: content}, "stdout": s};
 * paths are relative to VAR.
 */

#include <dirent.h>
#include <sys/stat.h>

static const char *opt_module, *opt_cfg;

/* ------------------------------------------------------------ the record -- */

static V opt_value(Str *s) { return s ? (V)s : None; }

static V dict_of(int n, const char **keys, V *vals)
{
    V d = mk_dict();
    int i;
    for (i = 0; i < n; i++)
        dict_set(d, mk_cstr(keys[i]), vals[i]);
    return d;
}

/* The directive record as a Starlark value: the JSON record of emit_json. */
static V record_value(void)
{
    V dirl = mk_list(ndirs), loads = mk_list(0);
    Module **mods;
    int i, j, n, rootlen = strlen(opt_root);
    for (i = 0; i < ndirs; i++) {
        Directive *d = &dirs[i];
        const char *k[8];
        V v[8];
        int m = 0;
        k[m] = "directive"; v[m++] = mk_cstr(d->kind);
        if (strcmp(d->kind, "version") == 0) {
            k[m] = "version"; v[m++] = (V)d->a;
            k[m] = "sha256"; v[m++] = opt_value(d->sha256);
            k[m] = "url"; v[m++] = opt_value(d->url);
            k[m] = "fname"; v[m++] = d->url || d->fname ? mk_cstr(default_fname(d)) : None;
        } else if (strcmp(d->kind, "resource") == 0) {
            k[m] = "sha256"; v[m++] = opt_value(d->sha256);
            k[m] = "url"; v[m++] = opt_value(d->url);
            k[m] = "fname"; v[m++] = mk_cstr(default_fname(d));
        } else if (strcmp(d->kind, "depends_on") == 0) {
            V t = mk_list(4);
            for (j = 0; dt_names[j]; j++)
                if (d->types & (1 << j))
                    list_append(t, mk_cstr(dt_names[j]));
            k[m] = "spec"; v[m++] = (V)d->a;
            k[m] = "type"; v[m++] = t;
        } else if (strcmp(d->kind, "patch") == 0) {
            k[m] = "file"; v[m++] = (V)d->a;
            k[m] = "level"; v[m++] = mk_int(d->level);
        } else if (strcmp(d->kind, "license") == 0) {
            k[m] = "license"; v[m++] = (V)d->a;
        } else if (strcmp(d->kind, "build_system") == 0) {
            V vals = mk_list(d->nvalues);
            for (j = 0; j < d->nvalues; j++) {
                const char *vk[2] = {"name", "when"};
                V vv[2];
                vv[0] = (V)d->values[j].a;
                vv[1] = opt_value(d->values[j].when);
                list_append(vals, dict_of(2, vk, vv));
            }
            k[m] = "values"; v[m++] = vals;
            k[m] = "default"; v[m++] = (V)d->a;
        }
        if (strcmp(d->kind, "version") != 0 && strcmp(d->kind, "build_system") != 0) {
            k[m] = "when"; v[m++] = opt_value(d->when);
        }
        list_append(dirl, dict_of(m, k, v));
    }
    n = loaded_modules(&mods);
    for (i = 0; i < n; i++) {
        const char *f = mods[i]->filename;
        if (strncmp(f, opt_repo, strlen(opt_repo)) == 0 && f[strlen(opt_repo)] == '/')
            continue;       /* the recipe itself */
        if (strncmp(f, opt_root, rootlen) == 0 && f[rootlen] == '/')
            f += rootlen + 1;
        list_append(loads, mk_cstr(f));
    }
    {
        const char *k[7] = {"name", "description", "homepage", "parallel",
                            "build_directory", "directives", "loads"};
        V v[7];
        v[0] = mk_cstr(recipe_name);
        v[1] = opt_value(pkg_description);
        v[2] = opt_value(pkg_homepage);
        v[3] = mk_bool(pkg_parallel);
        v[4] = opt_value(pkg_build_directory);
        v[5] = dirl;
        v[6] = loads;
        return dict_of(7, k, v);
    }
}

/* ---------------------------------------------------------------- host API -- */

static const char *conc_out;    /* VAR */

static void mkdir_p(const char *path)
{
    char *p = arena_strdup(path), *s;
    for (s = p + 1; *s; s++) {
        if (*s != '/')
            continue;
        *s = 0;
        mkdir(p, 0777);
        *s = '/';
    }
    mkdir(p, 0777);
}

static V h_recipe(Args *a)
{
    V name;
    Str *n;
    Buf path;
    struct stat st;
    V rec;
    unpack_positional(a, 1, 1, &name);
    n = want_str(name, "recipe");
    buf_init(&path);
    buf_printf(&path, "%s/%s/package.star", opt_repo, n->s);
    if (stat(buf_cstr(&path), &st) != 0)
        return None;
    /* a fresh evaluation: no directives, attributes or modules of the last */
    ndirs = 0;
    pkg_description = pkg_homepage = pkg_build_directory = NULL;
    pkg_parallel = 1;
    recipe_module = NULL;
    reset_modules();
    load_recipe(arena_strdup(n->s));
    load_build_systems();
    rec = record_value();
    reset_modules();
    return rec;
}

static int cmp_cstr(const void *x, const void *y)
{
    return strcmp(*(char *const *)x, *(char *const *)y);
}

static void sha256_file_hex(const char *path, char out[65])
{
    int len;
    char *src = read_file_or_die(path, &len);
    Sha256 s;
    sha256_init(&s);
    sha256_update(&s, src, len);
    sha256_hex(&s, out);
}

/* walk_files of spec.sh: depth first, sorted, no dotfiles */
static void walk(const char *dir, const char *rel, V out, int depth)
{
    DIR *d;
    struct dirent *e;
    char **names = NULL;
    int n = 0, cap = 0, i;
    if (depth > 32)
        star_error("files: %s: too deep", dir);
    if (!(d = opendir(dir)))
        return;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        if (n == cap) {
            int nc = cap ? cap * 2 : 16;
            names = arena_grow(names, sizeof(char *) * cap, sizeof(char *) * nc);
            cap = nc;
        }
        names[n++] = arena_strdup(e->d_name);
    }
    closedir(d);
    if (n)
        qsort(names, n, sizeof(char *), cmp_cstr);
    for (i = 0; i < n; i++) {
        Buf full, r;
        struct stat st;
        buf_init(&full);
        buf_printf(&full, "%s/%s", dir, names[i]);
        buf_init(&r);
        if (*rel)
            buf_printf(&r, "%s/%s", rel, names[i]);
        else
            buf_puts(&r, names[i]);
        if (stat(buf_cstr(&full), &st) != 0)
            continue;       /* dangling symlink */
        if (S_ISDIR(st.st_mode)) {
            walk(buf_cstr(&full), buf_cstr(&r), out, depth + 1);
        } else {
            char hex[65];
            V pair = mk_list(2);
            sha256_file_hex(buf_cstr(&full), hex);
            list_append(pair, mk_cstr(buf_cstr(&r)));
            list_append(pair, mk_cstr(hex));
            list_append(out, pair);
        }
    }
}

static V h_files(Args *a)
{
    V name, out = mk_list(0);
    Buf dir;
    unpack_positional(a, 1, 1, &name);
    buf_init(&dir);
    buf_printf(&dir, "%s/%s", opt_repo, want_str(name, "files")->s);
    walk(buf_cstr(&dir), "", out, 0);
    return out;
}

static V h_sha256(Args *a)
{
    V s;
    Sha256 h;
    char hex[65];
    unpack_positional(a, 1, 1, &s);
    sha256_init(&h);
    sha256_update(&h, want_str(s, "sha256")->s, AS_STR(s)->len);
    sha256_hex(&h, hex);
    return mk_cstr(hex);
}

static V h_sha256_file(Args *a)
{
    V p;
    char hex[65];
    unpack_positional(a, 1, 1, &p);
    sha256_file_hex(want_str(p, "sha256_file")->s, hex);
    return mk_cstr(hex);
}

static V h_read(Args *a)
{
    V p;
    char *src;
    int len;
    struct stat st;
    unpack_positional(a, 1, 1, &p);
    if (stat(want_str(p, "read")->s, &st) != 0 || !S_ISREG(st.st_mode))
        return None;
    src = read_file_or_die(AS_STR(p)->s, &len);
    return mk_str(src, len);
}

/* ------------------------------------------------------------------- main -- */

static V load_cfg(void)
{
    int len, i;
    char *src = read_file_or_die(opt_cfg, &len);
    ErrList errs;
    Module *m;
    V pre_saved = (V)predeclared;
    memset(&errs, 0, sizeof errs);
    predeclared = NULL;
    m = compile_module(opt_cfg, opt_cfg, src, len, &errs);
    if (!m) {
        for (i = 0; i < errs.n; i++)
            fprintf(stderr, "%s:%d:%d: %s\n", errs.pos[i].file, errs.pos[i].line,
                    errs.pos[i].col, errs.msg[i]);
        star_error("invalid cfg file %s", opt_cfg);
    }
    exec_module(m);
    predeclared = AS_DICT(pre_saved);
    reset_modules();
    for (i = 0; i < m->nglobals; i++)
        if (str_eq(m->gnames[i], "cfg") && m->globals[i] && TYPE(m->globals[i]) == T_DICT)
            return m->globals[i];
    star_error("%s: must assign a dict to cfg", opt_cfg);
    return NULL;
}

static void write_file(const char *rel, Str *content)
{
    Buf path;
    FILE *f;
    char *slash;
    if (rel[0] == '/' || strstr(rel, ".."))
        star_error("concretize: refusing to write %s", rel);
    buf_init(&path);
    buf_printf(&path, "%s/%s", conc_out, rel);
    slash = strrchr(path.p, '/');
    *slash = 0;
    mkdir_p(path.p);
    *slash = '/';
    if (!(f = fopen(path.p, "w")))
        star_error("cannot write %s", path.p);
    fwrite(content->s, 1, content->len, f);
    fclose(f);
}

int concretize_main(int argc, char **argv)
{
    V cfg, specs = mk_list(0), host, args[3], res, files, fn;
    Module *m;
    int i;
    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
#define OPT(flag, var) if (strcmp(a, flag) == 0 && i + 1 < argc) { var = argv[++i]; continue; }
        OPT("--repo", opt_repo);
        OPT("--root", opt_root);
        OPT("--module", opt_module);
        OPT("--cfg", opt_cfg);
        OPT("--out", conc_out);
#undef OPT
        if (a[0] == '-') {
            fprintf(stderr, "star concretize: unexpected argument %s\n", a);
            return 2;
        }
        list_append(specs, mk_cstr(a));
    }
    if (!opt_repo || !opt_root || !opt_module || !opt_cfg || !conc_out) {
        fprintf(stderr, "star concretize: --repo, --root, --module, --cfg and --out are required\n");
        return 2;
    }
    module_path_hook = root_path_hook;
    host_init();
    cfg = load_cfg();
    {
        const char *names[] = {"recipe", "files", "sha256", "sha256_file", "read", "star_version"};
        Str *sn[6];
        V sv[6];
        for (i = 0; i < 6; i++)
            sn[i] = intern(names[i]);
        sv[0] = mk_builtin("recipe", h_recipe, NULL);
        sv[1] = mk_builtin("files", h_files, NULL);
        sv[2] = mk_builtin("sha256", h_sha256, NULL);
        sv[3] = mk_builtin("sha256_file", h_sha256_file, NULL);
        sv[4] = mk_builtin("read", h_read, NULL);
        sv[5] = mk_cstr("star " STAR_VERSION);
        host = mk_struct("host", 6, sn, sv);
    }
    m = load_module(opt_module, NULL);
    fn = module_global(m, "concretize");
    if (!fn)
        star_error("%s: no function concretize", opt_module);
    args[0] = host;
    args[1] = cfg;
    args[2] = specs;
    res = call_simple(fn, 3, args);
    if (TYPE(res) != T_DICT)
        star_error("concretize: must return a dict, got %s", type_name(res));
    files = dict_get(res, mk_cstr("files"));
    if (!files || TYPE(files) != T_DICT)
        star_error("concretize: want a dict of files");
    for (i = 0; i < AS_DICT(files)->nents; i++) {
        V k = AS_DICT(files)->ents[i].key;
        if (!k)
            continue;
        write_file(want_str(k, "files")->s, want_str(AS_DICT(files)->ents[i].val, "files"));
    }
    {
        V out = dict_get(res, mk_cstr("stdout"));
        if (out && TYPE(out) == T_STRING)
            fwrite(AS_STR(out)->s, 1, AS_STR(out)->len, stdout);
    }
    return 0;
}
