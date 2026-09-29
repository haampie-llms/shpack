# SPDX-License-Identifier: MIT
#
# concretize.star -- resolve abstract specs to a concrete, hashed package DAG
# and emit the makefile that builds it. Run by `star concretize` (star/src/
# concretize.c) for `shpack concretize`; pure: every input comes from `host`
# and `cfg`, and the result is the state files to write under $VAR:
#
#   spec/<id>/        one dir per node, id = name-version: what the builder
#                     and `shpack env` read, nothing else
#     name, version, kind (built|external), hash, prefix
#     deps              direct dep ids, recipe order
#     edges             "ID TYPES" per direct dep, TYPES as in Spack (build,link,...)
#     closure           transitive dep ids, sorted
#     path              the build's PATH before BASEPATH: "DIR/bin:DIR/bin:..."
#     manifest          the package text behind the node's package hash (package_text)
#   and for built nodes, what the builder takes from the recipe:
#     sources           "SHA FNAME URL" per distfile: the version's, its resources'
#     patches           "FILE LEVEL" per patch that applies to this version and arch
#     parallel          present, "false", for a recipe that sets parallel = False
#   and for Spack (lib/spackdb.star, the prefix's .spack/spec.json):
#     spack.json        the node as a Spack spec node, under its Spack hash
#     spack-spec.json   a built node's spec.json: it and its closure
#     explicit          present for the requested (root) nodes
#   topo              all ids, dependencies before dependents
#   roots             ids of the requested packages
#   index             one line per node: NAME VERSION HASH KIND PREFIX
#   dag.mk            stamp-per-node makefile, scheduled by make
#
# Resolution is the greedy one of Spack's old concretizer, without its
# backtracking: `name@version` pins that exact version; a bare name is the
# first version its recipe declares; a recipe always beats an external
# (cfg["externals"], "name@version prefix" lines), which are the fallback for
# names with no recipe and for explicit version pins. A version listed in its
# recipe's kaem-steps is the kaem phase's (kind kaem): registered, not built.
#
# Starlark has no recursion or while: the depth-first walks keep their own
# stacks, and loop over a range that is far longer than any DAG.

_FOREVER = range(1 << 30)
_ARCHES = {"target=x86_64:": "amd64", "target=aarch64:": "aarch64"}
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

def _when_matches(when, version, arch = None):
    vs = _when_versions(when)
    if vs != None and version not in vs:
        return False
    for term in (when or "").split(" "):
        if term in _ARCHES and _ARCHES[term] != arch:
            return False
    return True

_B32 = "abcdefghijklmnopqrstuvwxyz234567"
_TARGETS = {"amd64": "x86_64", "aarch64": "aarch64"}
# The Spack namespace of shpack's recipes, as shpack/repo.yaml declares it: a
# Spack with that repo registered knows the recorded specs, so it reuses them.
_NAMESPACE = "bootstrap"
_SPECFILE_VERSION = 6    # spack.spec.SPECFILE_FORMAT_VERSION

def _b32pad(hexdigest):
    """base64.b32encode(digest).lower(), padding included: how Spack spells a
    package hash (the base32 SHA-256 of spack.package_base.content_hash)."""
    nbits = len(hexdigest) * 4
    out = []
    for i in range((nbits + 4) // 5):
        v = 0
        for b in range(5):
            bit = 5 * i + b
            v = v * 2
            if bit < nbits:
                v += (int(hexdigest[bit // 4], 16) >> (3 - bit % 4)) & 1
        out.append(_B32[v])
    return "".join(out) + "=" * ((8 - len(out) % 8) % 8)

def _b32(hexdigest):
    """The first 32 characters of the lowercase base32 encoding of a digest:
    all of a SHA-1's, which is how Spack spells a DAG hash (spack.util.hash.
    b32_hash)."""
    out = []
    for i in range(32):
        bit = 5 * i
        j = bit // 4
        byte = int(hexdigest[j:j + 2], 16)
        out.append(_B32[(byte >> (3 - bit % 4)) & 31])
    return "".join(out)

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

    kaem = {}
    def kaem_steps(name):
        """VERSION -> [STEP, INPUT...] from the recipe's kaem-steps: the versions
        the kaem phase installs (at $STORE/<name>-<version>), the step that
        builds each (shpack/bootstrap/STEP, or the seed) and the tree paths it
        reads, which the package text covers."""
        if name not in kaem:
            kaem[name] = {}
            for line in (host.read("%s/%s/kaem-steps" % (cfg["repo"], name)) or "").split("\n"):
                f = line.split()
                if f and not f[0].startswith("#"):
                    kaem[name][f[0]] = f[1:]
        return kaem[name]

    def resolve(spec):
        name, at, want = spec.partition("@")
        rec = record(name)
        if rec:
            for d in versions(rec):
                if at and d["version"] != want:
                    continue
                id = name + "-" + d["version"]
                if d["version"] in kaem_steps(name):
                    return struct(id = id, name = name, version = d["version"], kind = "kaem",
                                  prefix = store + "/" + id)
                return struct(id = id, name = name, version = d["version"], kind = "built",
                              prefix = None)
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
        if r.kind != "external" and record(r.name):
            for d in record(r.name)["directives"]:
                if d["directive"] == "depends_on" and _when_matches(d["when"], r.version):
                    deps.append((",".join(d["type"]), d["spec"]))
        active[r.id] = True
        return {"r": r, "deps": deps, "i": 0, "edges": []}

    def finish(f):
        r = f["r"]
        n = {"name": r.name, "version": r.version, "kind": r.kind, "deps": [], "edges": [],
             "closure": [], "order": [], "exec": [], "path": []}
        if r.kind != "external":
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
            if r.kind == "built":
                n["recipe"] = build_inputs(r)
        # The hash is Spack's DAG hash of the node as Spack records it: the
        # base32 SHA-1 of its JSON, which holds the dependencies' hashes and the
        # package hash (package_hash). A Spack with this repository (and the
        # star-recipes adapter) computes the same, so it installs where shpack
        # does. Stamps, logs and trees use the first 7, as `spack find -l`.
        n["manifest"] = package_text(r)
        node = spack_node(r, n, f["edges"])
        n["spack_hash"] = _b32(host.sha1(host.json(node, compact = True)))
        n["hash"] = n["spack_hash"][:7]
        node["hash"] = n["spack_hash"]
        n["spack"] = host.json(node)
        # Spack's default layout, {platform}-{target}/{name}-{version}-{hash};
        # the kaem phase's packages are unhashed, {name}-{version}.
        n["prefix"] = r.prefix if r.kind != "built" else "%s/linux-%s/%s-%s" % (
            store, _TARGETS.get(cfg["arch"], cfg["arch"]), r.id, n["spack_hash"])
        nodes[r.id] = n
        active.pop(r.id)
        topo.append(r.id)

    def spack_node(r, n, edges):
        """The node as Spack's Spec.to_node_dict makes it, key for key: what the
        DAG hash is computed over (spec.json and .spack-db add the hash)."""
        patches = [sha for sha, _ in applied_patches(r)]
        node = {
            "name": r.name,
            "version": r.version,
            "arch": {"platform": "linux", "platform_os": cfg.get("platform_os", "shpack"),
                     "target": _TARGETS.get(cfg["arch"], cfg["arch"])},
            "namespace": _NAMESPACE,
            # variants by name, then the compiler flags
            "parameters": {
                # the Spack side declares none (star/SPACK.md): the plan picks it
                "build_system": "generic",
            },
        }
        if patches:
            node["parameters"]["patches"] = sorted(patches)
        for flags in ["cflags", "cppflags", "cxxflags", "fflags", "ldflags", "ldlibs"]:
            node["parameters"][flags] = []
        if r.kind == "external":
            node["external"] = {"path": r.prefix, "module": None, "extra_attributes": {}}
        if patches:
            node["patches"] = patches   # in order of appearance
        node["package_hash"] = content_hash(r)
        # Every edge is a build edge, as Spack declares the recipe's (star/SPACK.md,
        # "Dependency types"): a reused node's link or run edges would pull their
        # targets into Spack's root unification set, which only link/run edges of
        # the package graph can reach. The recipe's types stay in spec/<id>/edges.
        deps = [{"name": nodes[d]["name"], "hash": nodes[d]["spack_hash"],
                 "parameters": {"deptypes": ["build"], "virtuals": []}} for d, _ in edges]
        if deps:
            node["dependencies"] = sorted(deps, key = lambda d: d["name"])
        node["annotations"] = {"original_specfile_version": _SPECFILE_VERSION}
        return node

    def sources(r):
        """(sha256, fname, url) of the version's source and its resources."""
        ds = record(r.name)["directives"]
        return [(d["sha256"], d["fname"] or "-", d["url"] or "-") for d in ds
                if d["directive"] == "version" and d["version"] == r.version and d["sha256"]] + [
                (d["sha256"], d["fname"], d["url"] or "-") for d in ds
                if d["directive"] == "resource" and _when_matches(d["when"], r.version)]

    def applied_patches(r):
        """(sha256, level) of the recipe's patches that apply, in recipe order."""
        if r.kind == "external":
            return []
        return [(host.sha256_file("%s/%s/patches/%s" % (cfg["repo"], r.name, d["file"])),
                 d["level"]) for d in record(r.name)["directives"]
                if d["directive"] == "patch" and _when_matches(d["when"], r.version, cfg["arch"])]

    def content_hash(r):
        """spack.package_base.content_hash, which Spack records as the package
        hash: the version's source digest, each applied patch as "SHA:LEVEL",
        and the base32 SHA-1 of the package text, sorted and concatenated."""
        digest = [d["sha256"] for d in (record(r.name) or {"directives": []})["directives"]
                  if d["directive"] == "version" and d["version"] == r.version and
                  d["sha256"]]
        parts = [digest[0] if digest else ""]
        parts += ["%s:%d" % p for p in applied_patches(r)]
        parts.append(_b32(host.sha1(package_text(r))))
        return _b32pad(host.sha256("".join(sorted(parts))))

    def build_inputs(r):
        """The builder's files from the recipe: sources, patches, parallel."""
        rec = record(r.name)
        files = {
            "sources": _lines(["%s %s %s" % s for s in sources(r)]),
            "patches": _lines(["%s %d" % (d["file"], d["level"]) for d in rec["directives"]
                               if d["directive"] == "patch" and
                               _when_matches(d["when"], r.version, cfg["arch"])]),
        }
        if not rec["parallel"]:
            files["parallel"] = "false\n"
        return files

    def package_text(r):
        """What Spack's package hash sees of a recipe (star_package.source_hash):
        everything that determines the build but the dependencies, which the
        DAG hash covers by their own hashes."""
        rec = record(r.name)
        out = ["package " + r.name, "version " + r.version, "arch " + cfg["arch"]]
        if not rec:
            return _lines(out)   # an external without a recipe
        out += ["source %s %s" % (sha, fname) for sha, fname, _ in sources(r)]
        for path, sha in host.files(r.name):
            out.append("file %s %s" % (sha, path))
        # A kaem step also depends on the tree it runs: its bootstrap step, and
        # for the seed stage0 and vendor/, by content, as "input SHA PATH".
        # "!PATH" leaves out what is under PATH (the seed's own build outputs).
        root = cfg["repo"] + "/../.."
        inputs = kaem_steps(r.name).get(r.version, [])[1:]
        skip = [p[1:] + "/" for p in inputs if p.startswith("!")]
        for path in inputs:
            if path.startswith("!"):
                continue
            if host.list(root + "/" + path) == None:
                out.append("input %s %s" % (host.sha256_file(root + "/" + path), path))
                continue
            for rel, sha in host.files("../../" + path):
                full = path + "/" + rel
                if not [s for s in skip if full.startswith(s)]:
                    out.append("input %s %s" % (sha, full))
        # A Starlark recipe also depends on the evaluator and on every module
        # it loads (build systems, helpers), by content.
        out.append("evaluator " + host.star_version)
        for path in rec["loads"]:
            out.append("load %s %s" % (host.sha256_file(cfg["star_root"] + "/" + path), path))
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
        for k in ["deps", "edges", "closure"]:
            files[d + k] = _lines(n[k])
        files[d + "manifest"] = n["manifest"]
        files[d + "path"] = compose_path(id) + "\n"
        for k, v in n.get("recipe", {}).items():
            files[d + k] = v
        # The node as Spack sees it, for the database (spackdb.star); and, for
        # a built node, the prefix's .spack/spec.json: it and its closure.
        files[d + "spack.json"] = n["spack"] + "\n"
        if n["kind"] != "external":
            ids = [id] + n["closure"]
            files[d + "spack-spec.json"] = (
                '{"spec": {"_meta": {"version": 6}, "nodes": [' +
                ", ".join([nodes[c]["spack"] for c in ids]) + "]}}\n")
    files["index"] = _lines(["%s %s %s %s %s" % (nodes[id]["name"], nodes[id]["version"],
                                                 nodes[id]["hash"], nodes[id]["kind"],
                                                 nodes[id]["prefix"]) for id in topo])
    for id in roots:
        if nodes[id]["kind"] != "external":
            files["spec/" + id + "/explicit"] = ""   # as `spack install` marks its roots
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
                                 if nodes[id]["kind"] != "external"]))
    out.append("")
    for id in topo:
        n = nodes[id]
        if n["kind"] == "external":
            continue
        prefix = n["prefix"]
        out.append("$(S)/%s:" % _stamp(nodes, id) +
                   "".join([" $(S)/" + _stamp(nodes, d) for d in n["deps"]
                            if nodes[d]["kind"] != "external"]))
        if n["kind"] == "kaem":
            # installed by the kaem phase: only its metadata goes in
            out.append("\t@%s %s/bin/shpack register-one %s >$(L)/%s.log 2>&1 \\" %
                       ("$(SHELL)", cfg["shpack_root"], id, id))
            out.append('\t  || { echo "!! %s FAILED, tail of $(L)/%s.log:"; tail -n 40 $(L)/%s.log; exit 1; }' %
                       (id, id, id))
            out.append("\t@touch $@")
            out.append("")
            continue
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
        # the log of the build that made the prefix: not if shpack or Spack
        # (which gzips it) left one already
        out.append(("\t@test -f %s/.spack/spack-build-out.txt -o -f %s/.spack/spack-build-out.txt.gz " +
                    "|| cp $(L)/%s.log %s/.spack/spack-build-out.txt") % (prefix, prefix, id, prefix))
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
