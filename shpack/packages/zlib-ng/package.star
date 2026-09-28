# SPDX-License-Identifier: MIT

"""zlib-ng 2.3.3 -- a zlib replacement with optimizations for modern systems.
Built in --zlib-compat mode, so it installs zlib.h and a drop-in libz.so.1
carrying the classic zlib ABI."""

homepage = "https://github.com/zlib-ng/zlib-ng"
license("Zlib")

# GitHub source archive (extracts zlib-ng-2.3.3/). The archive carries a
# hand-written ./configure (autotools-free), so no autoconf is needed.
version(
    "2.3.3",
    sha256 = "f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1",
    url = "https://github.com/zlib-ng/zlib-ng/archive/2.3.3.tar.gz",
    fname = "zlib-ng-2.3.3.tar.gz",
)

# 2.3.3-boot: same source, but a static-only libz.a built in the toolchain
# layer (by gcc-boot-wrapper, against glibc) so gcc/binutils can link zlib
# statically -- no shared-lib resolution in the hot compiler path.
version(
    "2.3.3-boot",
    sha256 = "f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1",
    url = "https://github.com/zlib-ng/zlib-ng/archive/2.3.3.tar.gz",
    fname = "zlib-ng-2.3.3.tar.gz",
)

build_system("generic")

depends_on("dash", type = "build")

# 2.3.3: app-layer shared build via compiler-wrapper (final gcc 16).
when("@=2.3.3", [
    depends_on("compiler-wrapper", type = "build"),
    depends_on("gmake", type = "build"),
    depends_on("sed@4.9-musl", type = "build"),
    depends_on("grep-boot", type = "build"),
    depends_on("gawk@5.3.1", type = "build"),
    depends_on("diffutils", type = "build"),
    depends_on("findutils", type = "build"),
    depends_on("tar@1.35-musl", type = "build"),
    depends_on("xz@5.2.5-musl", type = "build"),
])

# 2.3.3-boot: toolchain-layer static build by gcc-boot-wrapper.
when("@=2.3.3-boot", [
    depends_on("gcc-boot-wrapper", type = "build"),
    depends_on("glibc"),
    depends_on("gmake", type = "build"),
    depends_on("sed@4.9-musl", type = "build"),
    depends_on("grep-boot", type = "build"),
    depends_on("gawk@5.3.1", type = "build"),
    depends_on("diffutils", type = "build"),
    depends_on("findutils", type = "build"),
    depends_on("tar@1.35-musl", type = "build"),
    depends_on("xz@5.2.5-musl", type = "build"),
])

def install(ctx):
    # zlib-ng ships its own configure (not autotools); it honours $CC.
    # --zlib-compat builds the classic-ABI libz (zlib.h + the zlib ABI).
    if ctx.satisfies("@=2.3.3-boot"):
        # Wrapper supplies glibc loader/libs but not headers; add them.
        # --static builds libz.a only (no .so), forcing static linking.
        glibc = ctx.dep("glibc").prefix
        env = [
            setenv("CC", ctx.dep("gcc-boot-wrapper").prefix + "/bin/gcc"),
            setenv("C_INCLUDE_PATH", glibc + "/include"),
            setenv("LIBRARY_PATH", glibc + "/lib"),
        ]
        extra = ["--static"]
    else:
        env = [setenv("CC", ctx.dep("compiler-wrapper").prefix + "/bin/gcc")]
        extra = []
    return env + [
        run(ctx.sh, "./configure", "--prefix=" + ctx.prefix, "--zlib-compat", extra),
        run("make", ctx.makejobs),
        run("make", "install"),
    ]
