# SPDX-License-Identifier: MIT

"""Spack v1.2.0 (releases/v1.2 snapshot) -- the package manager, installed into
the store and wired to run on the shpack-built CPython with the shpack-built
clingo as its concretizer, so it never bootstraps prebuilt clingo. The
'builtin' package repo is overridden to the vendored spack-packages, so 'spack
spec' works offline."""

homepage = "https://spack.io/"
license("Apache-2.0 OR MIT")

# releases/v1.2 head (commit 3d24b94, 2026-06-11); __version__ is 1.2.0.dev0.
# GitHub commit archive -> stable checksum.
version(
    "1.2.0",
    sha256 = "3efca6d5892930ee998a81c5917747765f107ffb0f9de9a03209159726df3b8f",
    url = "https://github.com/spack/spack/archive/3d24b94ef3d15a4864794f98807a7fcc17b83f48.tar.gz",
    fname = "spack-1.2.0.tar.gz",
)

build_system("generic")

# cpython runs it; clingo (on PYTHONPATH) is the concretizer; spack-packages is
# the 'builtin' repo; gcc is the compiler Spack auto-detects. The rest are the
# gcc-16/glibc userland (Spack otherwise assumes the host's), put on the launcher
# PATH -- bare names, so each resolves to its user-facing (glibc) version.
depends_on("cpython", type = ("build", "run"))
depends_on("clingo", type = ("build", "run"))
depends_on("spack-packages", type = ("build", "run"))
depends_on("gcc", type = ("build", "run"))
depends_on("coreutils", type = ("build", "run"))
depends_on("grep", type = ("build", "run"))
depends_on("sed", type = ("build", "run"))
depends_on("gawk", type = ("build", "run"))
depends_on("tar", type = ("build", "run"))
depends_on("xz", type = ("build", "run"))
depends_on("bzip2", type = ("build", "run"))
depends_on("gzip", type = ("build", "run"))
depends_on("patch", type = ("build", "run"))
depends_on("unzip", type = ("build", "run"))
depends_on("zstd", type = ("build", "run"))
depends_on("git", type = ("build", "run"))
# The launcher is a #!$sh script, so the clean glibc dash is a runtime dep.
depends_on("dash", type = ("build", "run"))

def install(ctx):
    py = ctx.dep("cpython").prefix
    gcc = ctx.dep("gcc").prefix
    clingo_site = ctx.dep("clingo").prefix + "/lib/python3.14/site-packages"
    pkgrepo = ctx.dep("spack-packages").prefix + "/repos/spack_repo/builtin"
    dest = ctx.prefix + "/lib/spack-" + ctx.version

    # Colon-terminated bin/ list of the gcc-16-built userland for the launcher PATH.
    tools = "".join([
        ctx.dep(t).prefix + "/bin:"
        for t in ["coreutils", "grep", "sed", "gawk", "tar", "xz", "bzip2", "gzip", "patch", "unzip", "zstd", "git"]
    ])

    return [
        mkdir(dest),
        copy(".", dest + "/", preserve = True),
        # Override the 'builtin' repo (default: a git clone) with the vendored path.
        # The instance scope ($spack/etc/spack) overrides the defaults scope.
        write_file(dest + "/etc/spack/repos.yaml", "repos:\n  builtin: %s\n" % pkgrepo),
        # Launcher: our Python + clingo on PYTHONPATH so Spack skips bootstrapping.
        # SPACK_DISABLE_LOCAL_CONFIG is deliberately unset -- it would drop every local
        # scope at once, making SPACK_USER_CONFIG_PATH a no-op. The tradeoff is the run
        # isn't hermetic against host Spack config, which is the price of overridability.
        mkdir(ctx.prefix + "/bin"),
        write_file(
            ctx.prefix + "/bin/spack",
            "#!%s\n" % ctx.sh +
            "export PATH=%s/bin:%s%s/bin:$PATH\n" % (gcc, tools, py) +
            "export PYTHONPATH=%s${PYTHONPATH:+:$PYTHONPATH}\n" % clingo_site +
            "exec %s/bin/python3 %s/bin/spack \"$@\"\n" % (py, dest),
            mode = "755",
        ),
    ]
