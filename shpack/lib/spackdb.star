# SPDX-License-Identifier: MIT
#
# spackdb.star -- the store's Spack database, $STORE/.spack-db/index.json, so
# that Spack reads a shpack store as its own install tree, in place:
#
#     spack config add config:install_tree:root:$STORE
#     spack find
#
# The store is laid out as Spack lays out its own ({platform}-{target}/{name}-
# {version}-{hash}), and an installed prefix is one with .spack/spec.json,
# for shpack as for Spack. Run by `star concretize --entry spack_db` after
# `shpack install`, this merges the nodes of that concretization ($VAR/spec/
# <id>/spack.json, concretize.star) into the database:
#
# - Every record already there is kept: Spack may own part of the store (a
#   package it installed, or an `install --overwrite` of one of shpack's).
# - A node installed now -- its prefix has .spack/spec.json, or it is a
#   kaem-phase external -- is recorded as installed unless it already was;
#   a requested (root) node is marked explicit, as `spack install` does.
# - ref_count is recounted over the whole database, as Spack counts it: the
#   records that depend on a node.
#
# A store without a database, or with one that lost track of the prefixes:
# `spack reindex` rebuilds it from the prefixes' spec.json.

_DB_VERSION = "9"   # Spack's database format (spack.database._DB_VERSION)

def spack_db(host, cfg, specs):
    index = cfg["store"] + "/.spack-db/index.json"
    installs = {}
    text = host.read(index)
    if text != None:
        db = host.json_decode(text)["database"]
        if db["version"] != _DB_VERSION:
            fail("%s is version %s, not %s: run `spack reindex` first" %
                 (index, db["version"], _DB_VERSION))
        installs = db["installs"]

    var = cfg["var"]
    for id in (host.read(var + "/topo") or "").split("\n"):
        if not id:
            continue
        d = var + "/spec/" + id + "/"
        kind = host.read(d + "kind").strip()
        prefix = host.read(d + "prefix").strip()
        spec = host.json_decode(host.read(d + "spack.json"))
        h = spec["hash"]
        if kind == "external":
            installed = True
        else:
            installed = host.read(prefix + "/.spack/spec.json") != None
        if not installed:
            continue    # not built (yet): nothing depends on it in the database
        old = installs.get(h)
        explicit = host.read(d + "explicit") != None
        if old != None and old["installed"]:
            old["explicit"] = old["explicit"] or explicit
            continue
        t = (host.read(d + "installation_time") or "0").strip()
        installs[h] = {
            "spec": spec,
            "ref_count": 0,
            "path": prefix,
            "installed": True,
            "explicit": explicit or (old != None and old["explicit"]),
            "installation_time": int(t) if t.isdigit() else 0,
            "deprecated_for": None,
        }

    refs = {h: 0 for h in installs}
    for h in installs:
        for dep in installs[h]["spec"].get("dependencies", []):
            if dep["hash"] in refs:
                refs[dep["hash"]] += 1
    for h in installs:
        installs[h]["ref_count"] = refs[h]

    out = host.json({"database": {"version": _DB_VERSION, "installs": installs}}) + "\n"
    return {
        "files": {
            ".spack-db/index.json": out,
            # Spack re-reads the index when this changes
            ".spack-db/index_verifier": host.sha256(out),
        },
        "stdout": "",
    }
