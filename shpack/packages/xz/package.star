# SPDX-License-Identifier: MIT

"""XZ Utils -- real liblzma xz/unxz. Two builds from one recipe: 5.2.5-musl is
the static musl xz the bootstrap uses for the big .tar.xz extractions (linux
144M, gcc 102M/72M, glibc 20M) before the final toolchain exists; 5.8.3 is the
glibc xz built with the final gcc 16, the user-facing (de)compressor."""

load("//build_systems/lib.star", "triple")

homepage = "https://tukaani.org/xz/"
license("0BSD AND LGPL-2.1-or-later AND GPL-2.0-or-later")

# 5.8.3 (2025): current stable, clear of the 5.6.0/5.6.1 backdoor; the glibc xz.
version(
    "5.8.3",
    sha256 = "33bf69c0d6c698e83a68f77e6c1f465778e418ca0b3d59860d3ab446f4ac99a6",
    url = "https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.bz2",
)
# 5.2.5-musl (2021): pre-dates the backdoor, builds clean with GCC 4.7 on musl.
# Shipped as .tar.gz (seed gzip) so xz never decompresses its own source.
version(
    "5.2.5-musl",
    sha256 = "f6f4910fd033078738bd82bfba4f49219d03b17eb0794eb91efbae419f4aba10",
    url = "https://downloads.sourceforge.net/project/lzmautils/xz-5.2.5.tar.gz",
)

build_system("autotools")

# 5.8.3: the glibc xz, built with the final gcc 16 via compiler-wrapper.
when("@=5.8.3", [
    depends_on("compiler-wrapper", type = "build"),
    depends_on("gmake", type = "build"),
    depends_on("sed@4.9-musl", type = "build"),
    depends_on("grep-boot", type = "build"),
    depends_on("gawk@5.3.1", type = "build"),
    depends_on("diffutils", type = "build"),
    depends_on("findutils", type = "build"),
    depends_on("tar@1.35-musl", type = "build"),
    depends_on("dash", type = "build"),
])

# 5.2.5-musl: GCC 4.7 against musl 1.1.24 (static).
when("@=5.2.5-musl", [
    depends_on("gcc-boot0", type = "build"),
    depends_on("binutils-boot0", type = "build"),
    depends_on("gmake", type = "build"),
    depends_on("grep-boot", type = "build"),
    depends_on("gawk-boot", type = "build"),
    depends_on("diffutils", type = "build"),
    depends_on("findutils", type = "build"),
    depends_on("dash@0.5.12", type = "build"),
])

def configure_args(ctx):
    musl = ctx.satisfies("@=5.2.5-musl")
    # Explicit triple (no config.guess); the only common-flag diff.
    t = triple(ctx, "musl", vendor = "unknown") if musl else triple(ctx)
    args = [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--disable-nls",
        "--disable-doc",
    ]
    # musl build: static-only liblzma + CLI (drop scripts/symbol-versions), and
    # CFLAGS=-O2 drops gcc-4.7's -g (would leak the build cwd as comp_dir). The
    # gcc 16 build keeps the shared liblzma and the default -g.
    if musl:
        args += [
            "CFLAGS=-O2",
            "--disable-shared",
            "--enable-static",
            "--disable-scripts",
            "--disable-symbol-versions",
        ]
    return args
