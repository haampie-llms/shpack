# SPDX-License-Identifier: MIT
#
# makefile -- packages driven by a makefile: upstream's, or a replacement the
# recipe ships as files/Makefile (the bootstrap pattern for packages whose own
# build system needs tools that do not exist yet).
#
# Hooks: build_targets, install_targets (extra make arguments). make is
# always run with -f Makefile: some tarballs ship a GNUmakefile, which GNU
# make would otherwise prefer over a replacement Makefile.

load("//build_systems/lib.star", "hook")

phases = ["edit", "build", "install"]

def edit(ctx):
    if "files/Makefile" in ctx.package_files:
        return [copy(ctx.package_dir + "/files/Makefile", "Makefile")]
    return []

def build(ctx):
    return [run("make", "-f", "Makefile", "SHELL=" + ctx.sh, ctx.makejobs,
                "PREFIX=" + ctx.prefix, hook(ctx, "build_targets", []))]

def install(ctx):
    targets = hook(ctx, "install_targets", []) or ["install"]
    return [run("make", "-f", "Makefile", "SHELL=" + ctx.sh, "PREFIX=" + ctx.prefix, targets)]
