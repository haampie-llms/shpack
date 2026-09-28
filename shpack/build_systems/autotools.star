# SPDX-License-Identifier: MIT
#
# autotools -- packages with a pregenerated ./configure (there is no autoconf
# in the bootstrap; tarballs must ship configure).
#
# Hooks: configure_args, build_args, install_targets -- lists of arguments,
# which may contain spaces ("AR=tcc -ar"); configure also takes VAR=value.

load("//build_systems/lib.star", "hook")

phases = ["edit", "configure", "build", "install"]

def edit(ctx):
    return []

def configure(ctx):
    actions = []
    cfg = "./configure"
    if ctx.build_directory:
        # Out of tree (gcc/glibc forbid in-tree builds): cd into the build
        # directory, which later phases inherit, and run configure by a
        # RELATIVE path. GCC bakes its invocation into the compiler
        # (`gcc -v`) and derives srcdir from it, so an absolute scratch path
        # would leak into configargs and every __FILE__.
        up = "/".join([".." for part in ctx.build_directory.split("/") if part])
        actions = [mkdir(ctx.build_directory), chdir(ctx.build_directory)]
        cfg = up + "/configure"

    # configure runs through the build shell explicitly rather than its
    # #!/bin/sh (there is none); CONFIG_SHELL= and SHELL= make it use the same
    # shell for the makefiles it writes and for sub-configures.
    # --disable-dependency-tracking: one-shot builds never rebuild
    # incrementally, so automake's depcomp machinery is pure overhead.
    return actions + [run(
        ctx.sh,
        cfg,
        "--prefix=" + ctx.prefix,
        "--disable-dependency-tracking",
        "CONFIG_SHELL=" + ctx.sh,
        "SHELL=" + ctx.sh,
        hook(ctx, "configure_args", []),
    )]

def build(ctx):
    return [run("make", "SHELL=" + ctx.sh, ctx.makejobs, hook(ctx, "build_args", []))]

def install(ctx):
    targets = hook(ctx, "install_targets", []) or ["install"]
    return [run("make", "SHELL=" + ctx.sh, targets)]
