# SPDX-License-Identifier: MIT
#
# generic -- packages with a bespoke build: the recipe defines install() and
# does everything there (edit() is optional).

phases = ["edit", "install"]

def edit(ctx):
    return []

def install(ctx):
    fail("%s: build_system generic requires the recipe to define install()" % ctx.name)
