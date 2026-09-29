# SPDX-License-Identifier: MIT

"""GNU sed 4.9 -- a modern stream editor. The stage0 seed sed is 4.0.9 (2003),
too old for 'sed -E' and other scripts the kernel headers, glibc and gcc build
machinery rely on. Two builds from one recipe: 4.9-musl is the static musl sed
the bootstrap chain uses; 4.9 is the glibc sed built with the final gcc 16, the
user-facing one."""

load("//build_systems/lib.star", "triple")

homepage = "https://www.gnu.org/software/sed/"
license("GPL-3.0-or-later")

version(
    "4.9",
    sha256 = "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181",
    url = "https://ftpmirror.gnu.org/sed/sed-4.9.tar.xz",
)
version(
    "4.9-musl",
    sha256 = "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181",
    url = "https://ftpmirror.gnu.org/sed/sed-4.9.tar.xz",
)

build_system("autotools")

# Each version pulls the matching xz for its source.

# 4.9: the glibc sed, built with the final gcc 16 via compiler-wrapper.
when("@=4.9", [
    depends_on("compiler-wrapper", type = "build"),
    depends_on("gmake", type = "build"),
    depends_on("xz", type = "build"),
    depends_on("grep-boot", type = "build"),
    depends_on("gawk@5.3.1", type = "build"),
    depends_on("diffutils", type = "build"),
    depends_on("findutils", type = "build"),
    depends_on("tar@1.35-musl", type = "build"),
    depends_on("dash", type = "build"),
])

# 4.9-musl: GCC 4.7 against musl 1.1.24 (static).
when("@=4.9-musl", [
    depends_on("gcc-boot0", type = "build"),
    depends_on("binutils-boot0", type = "build"),
    depends_on("gmake", type = "build"),
    depends_on("xz@5.2.5-musl", type = "build"),
    depends_on("grep-boot", type = "build"),
    depends_on("gawk-boot", type = "build"),
    depends_on("diffutils", type = "build"),
    depends_on("findutils", type = "build"),
    depends_on("dash-boot", type = "build"),
])

def configure_args(ctx):
    musl = ctx.satisfies("@=4.9-musl")
    # Explicit triple (no config.guess); the only common-flag diff.
    t = triple(ctx, "musl", vendor = "unknown") if musl else triple(ctx)
    args = [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
    ]
    # gcc 4.7 has no -ffile-prefix-map, so CFLAGS=-O2 drops the default -g (would
    # leak the build cwd as comp_dir). gcc 16's -g is reproducible.
    if musl:
        args.append("CFLAGS=-O2")
    return args
