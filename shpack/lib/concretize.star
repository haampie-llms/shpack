# SPDX-License-Identifier: MIT
#
# concretize.star -- resolve abstract specs to a concrete, hashed package DAG
# and emit the makefile that builds it. Run by `star concretize` (star/src/
# concretize.c) for `shpack concretize`; pure: every input comes from `host`
# and `cfg`, and the result is the state files to write under $VAR:
#
#   spec/<id>/        one dir per node, id = name-version
#     name, version, kind (built|external), hash, prefix
#     deps              direct dep ids, recipe order
#     edges             "ID TYPES" per direct dep, TYPES as in Spack (build,link,...)
#     closure           transitive dep ids, sorted
#     order             the closure in DFS post-order over declared deps
#     exec              what a dependent may run through this node: its run
#                       deps, and theirs and its link deps' (Spack's
#                       RUNTIME_EXECUTABLE); for a dependent's PATH
#     path              whose bin/ this node's build puts on PATH: every build
#                       dep, plus its exec
#     manifest          the canonical hash input (kept for auditability)
#   topo              all ids, dependencies before dependents
#   roots             ids of the requested packages
#   index             one line per node: NAME VERSION HASH KIND PREFIX
#   dag.mk            stamp-per-node makefile, scheduled by make
#
# Resolution is the greedy one of Spack's old concretizer, without its
# backtracking: `name@version` pins that exact version; a bare name is the
# first version its recipe declares; a recipe always beats an external
# (cfg["externals"], "name@version prefix" lines), which are the fallback for
# names with no recipe and for explicit pins onto kaem-phase seeds.
#
# Starlark has no recursion or while: the depth-first walks keep their own
# stacks, and loop over a range that is far longer than any DAG.

_FOREVER = range(1 << 30)
_TYPE_LETTERS = [("build", "b"), ("link", "l"), ("run", "r"), ("test", "t")]

def _lines(items):
    return "".join([x + "\n" for x in items])

def _when_versions(when):
    """The versions of a when= string ("@=V1,=V2 target=..."), or None for any."""
    if when == None:
        return None
    for term in when.split(" "):
        if term.startswith("@"):
            return [v[1:] for v in term[1:].split(",")]
    return None

def _when_matches(when, version):
    vs = _when_versions(when)
    return vs == None or version in vs

def _add(lst, x):
    if x not in lst:
        lst.append(x)

def concretize(host, cfg, specs):
    if not specs:
        fail("usage: shpack concretize <spec>...")
    store = cfg["store"]
    records = {}

    def record(name):
        if name not in records:
            records[name] = host.recipe(name)
        return records[name]

    externals = []
    text = host.read(cfg["externals"])
    for line in (text or "").split("\n"):
        fields = line.strip(" \t").split(None, 1)
        if not fields or fields[0].startswith("#"):
            continue
        externals.append((fields[0], fields[1].strip(" \t") if len(fields) > 1 else ""))

    def versions(rec):
        return [d for d in rec["directives"] if d["directive"] == "version"]

    def resolve(spec):
        name, at, want = spec.partition("@")
        rec = record(name)
        if rec:
            for d in versions(rec):
                if at and d["version"] != want:
                    continue
                return struct(id = name + "-" + d["version"], name = name, version = d["version"],
                              kind = "built", prefix = None)
        for ename, eprefix in externals:
            if ename.partition("@")[0] != name:
                continue
            v = ename.partition("@")[2] if "@" in ename else ename
            if at and v != want:
                continue
            if not eprefix.startswith("/"):
                eprefix = store + "/" + eprefix
            return struct(id = name + "-" + v, name = name, version = v, kind = "external",
                          prefix = eprefix)
        fail("cannot resolve '%s': no recipe or external version matches" % spec)

    nodes = {}      # id -> dict, once finished
    active = {}     # ids on the DFS stack: a second visit is a cycle
    topo = []

    def start(r):
        """A stack frame for the resolved node r, with its dependency list."""
        deps = []
        if r.kind == "built" and record(r.name):
            for d in record(r.name)["directives"]:
                if d["directive"] == "depends_on" and _when_matches(d["when"], r.version):
                    deps.append((",".join(d["type"]), d["spec"]))
        active[r.id] = True
        return {"r": r, "deps": deps, "i": 0, "edges": []}

    def finish(f):
        r = f["r"]
        n = {"name": r.name, "version": r.version, "kind": r.kind, "deps": [], "edges": [],
             "closure": [], "order": [], "exec": [], "path": []}
        if r.kind == "external":
            # Identity only: the prefix is a deployment detail, and hashing it
            # would make every hash depend on where the store lives.
            n["manifest"] = "external %s %s\n" % (r.name, r.version)
        else:
            closure = []
            for depid, types in f["edges"]:
                dep = nodes[depid]
                n["deps"].append(depid)
                n["edges"].append(depid + " " + types)
                closure += [depid] + dep["closure"]
                for c in dep["order"] + [depid]:
                    _add(n["order"], c)
                # What goes on PATH, as Spack decides it: a build dep, and
                # what it runs -- its run deps, through run and link edges.
                t = types.split(",")
                if "run" in t:
                    _add(n["exec"], depid)
                if "run" in t or "link" in t:
                    for c in dep["exec"]:
                        _add(n["exec"], c)
                if "build" in t or "test" in t:
                    for c in [depid] + dep["exec"]:
                        _add(n["path"], c)
            n["closure"] = sorted({c: None for c in closure}.keys())
            n["manifest"] = manifest(r, f["edges"])
        n["hash"] = host.sha256(n["manifest"])[:7]
        n["prefix"] = r.prefix if r.kind == "external" else "%s/%s-%s" % (store, r.id, n["hash"])
        nodes[r.id] = n
        active.pop(r.id)
        topo.append(r.id)

    def manifest(r, edges):
        rec = record(r.name)
        out = ["package " + r.name, "version " + r.version, "arch " + cfg["arch"]]
        for d in rec["directives"]:
            if d["directive"] == "version" and d["version"] == r.version and d["sha256"]:
                out.append("source %s %s" % (d["sha256"], d["fname"] or "-"))
        for d in rec["directives"]:
            if d["directive"] == "resource" and _when_matches(d["when"], r.version):
                out.append("source %s %s" % (d["sha256"], d["fname"]))
        for path, sha in host.files(r.name):
            out.append("file %s %s" % (sha, path))
        # A Starlark recipe also depends on the evaluator and on every module
        # it loads (build systems, helpers), by content.
        out.append("evaluator " + host.star_version)
        for path in rec["loads"]:
            out.append("load %s %s" % (host.sha256_file(cfg["star_root"] + "/" + path), path))
        out += sorted(["dep %s %s %s %s" % (nodes[d]["name"], nodes[d]["version"],
                                            nodes[d]["hash"], t) for d, t in edges])
        return _lines(out)

    def visit(spec):
        """Resolve spec and materialize its node and everything below it; its id."""
        root = resolve(spec)
        if root.id in nodes:
            return root.id
        stack = [start(root)]
        for _ in _FOREVER:
            if not stack:
                break
            f = stack[-1]
            if f["i"] == len(f["deps"]):
                finish(stack.pop())
                continue
            types, dep = f["deps"][f["i"]]
            f["i"] += 1
            r = resolve(dep)
            if r.id in active:
                fail("dependency cycle through %s" % r.id)
            f["edges"].append((r.id, types))
            if r.id not in nodes:
                stack.append(start(r))
        return root.id

    roots = [visit(s) for s in specs]

    def compose_path(id):
        n = nodes[id]
        out = n["prefix"] + "/bin:"
        for c in reversed(n["order"]):
            if c in n["path"]:
                out += nodes[c]["prefix"] + "/bin:"
        return out

    files = {"topo": _lines(topo), "roots": _lines(roots)}
    for id in topo:
        n = nodes[id]
        d = "spec/" + id + "/"
        for k in ["name", "version", "kind", "hash", "prefix"]:
            files[d + k] = n[k] + "\n"
        for k in ["deps", "edges", "closure", "order", "exec", "path"]:
            files[d + k] = _lines(n[k])
        files[d + "manifest"] = n["manifest"]
    files["index"] = _lines(["%s %s %s %s %s" % (nodes[id]["name"], nodes[id]["version"],
                                                 nodes[id]["hash"], nodes[id]["kind"],
                                                 nodes[id]["prefix"]) for id in topo])
    files["dag.mk"] = dagmk(cfg, nodes, topo, roots, compose_path)
    out = tree(nodes, roots)
    out += "concretized %d node(s); makefile at %s/dag.mk\n" % (len(topo), cfg["var"])
    return {"files": files, "stdout": out}

def _stamp(nodes, id):
    return "%s-%s" % (id, nodes[id]["hash"])

def dagmk(cfg, nodes, topo, roots, compose_path):
    """One stamp target per built node; direct built deps as prerequisites
    (make supplies transitivity); the recipe runs `shpack build-one` in its own
    process with the precomposed PATH, logging to one file per package. '+'
    marks the recipe recursive so MAKEFLAGS (jobserver) reaches inner makes.
    Compatible with make 3.82, the only scheduler alive at shell-phase start."""
    sandbox = cfg["sandbox"]
    out = [
        "# Generated by shpack concretize. Do not edit.",
        "SHELL := " + cfg["config_shell"],
        "S := %s/stamps" % cfg["var"],
        "L := %s/logs" % cfg["var"],
        "BASEPATH := " + cfg["basepath"],
    ]
    # Sandbox knobs, emitted only when configured: each build step is wrapped
    # in $(SANDBOX), confined to the store (read+exec), recipe tree + distfiles
    # (read), and its own prefix + scratch (write).
    if sandbox:
        out += [
            "SANDBOX := " + sandbox,
            "STORE := " + cfg["store"],
            "SHPACK := " + cfg["shpack_root"],
            "REPO := " + cfg["repo"],
            "DISTFILES := " + cfg["distfiles"],
            "V := " + cfg["var"],
        ]
    out.append("")
    out.append(".PHONY: all")
    out.append("all:" + "".join([" $(S)/" + _stamp(nodes, id) for id in roots
                                 if nodes[id]["kind"] == "built"]))
    out.append("")
    for id in topo:
        n = nodes[id]
        if n["kind"] != "built":
            continue
        prefix = n["prefix"]
        out.append("$(S)/%s:" % _stamp(nodes, id) +
                   "".join([" $(S)/" + _stamp(nodes, d) for d in n["deps"]
                            if nodes[d]["kind"] == "built"]))
        # The sandbox needs the prefix to exist before it can grant write to
        # it; $(V) grants the whole scratch. The log redirect, touch and cp run
        # outside the wrapper.
        pre, wrap = "", ""
        if sandbox:
            pre = "mkdir -p %s; " % prefix
            wrap = ("$(SANDBOX) --read $(STORE) --read $(SHPACK) --read $(REPO) " +
                    "--read $(DISTFILES) --write $(V) --write %s -- " % prefix)
        out.append("\t+@%sPATH=%s$(BASEPATH) \\" % (pre, compose_path(id)))
        out.append("\t  %s$(SHELL) %s/bin/shpack build-one %s >$(L)/%s.log 2>&1 \\" %
                   (wrap, cfg["shpack_root"], id, id))
        out.append('\t  || { echo "!! %s FAILED, tail of $(L)/%s.log:"; tail -n 40 $(L)/%s.log; exit 1; }' %
                   (id, id, id))
        out.append("\t@test -f %s/.shpack/build.log || cp $(L)/%s.log %s/.shpack/build.log" %
                   (prefix, id, prefix))
        # Post-install marker, Spack-style, so the prefix is copy-pasteable.
        out.append('\t@echo "[+] %s %s@%s %s"' % (n["hash"], n["name"], n["version"], prefix))
        out.append("\t@touch $@")
        out.append("")
    return _lines(out)

def tree(nodes, roots):
    """The DAG as an indented tree, as `spack spec -t` prints it: each node once,
    under the first parent that reaches it; the hash, the types of that edge
    ([bl  ]: build, link, run, test), then name@version."""
    out = []
    seen = {}
    stack = [("", "-", id) for id in reversed(roots)]
    for _ in _FOREVER:
        if not stack:
            break
        indent, types, id = stack.pop()
        if id in seen:
            continue
        seen[id] = True
        n = nodes[id]
        t = types.split(",")
        letters = "".join([c if name in t else " " for name, c in _TYPE_LETTERS])
        tag = " (external)" if n["kind"] == "external" else ""
        out.append("%s  [%s]  %s%s@%s%s" % (n["hash"], letters, indent, n["name"], n["version"], tag))
        for e in reversed(n["edges"]):
            dep, _, dtypes = e.partition(" ")
            stack.append((indent + "  ", dtypes, dep))
    return _lines(out)
