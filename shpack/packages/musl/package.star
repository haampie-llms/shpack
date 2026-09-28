# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "replace_bin_sh", "triple")

package(
    description = "musl libc 1.2.5 -- modern, pristine static libc, rebuilt by the "
                  + "chain's real GCC 4.7 (sysroot for the gcc 9.5 bridge)",
    homepage = "https://musl.libc.org/",
    license = "MIT",
)

# 1.1.24 stays the kaem-phase external (tcc-built); this recipe adds the modern
# 1.2.5, built cleanly by gcc 4.7.
version(
    "1.2.5",
    sha256 = "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4",
    url = "https://www.musl-libc.org/releases/musl-1.2.5.tar.gz",
)

build_system("generic")

depends_on("gcc-boot0", "binutils-boot0", "gmake", "linux-headers")
depends_on("dash@0.5.12")

def setup_build_environment(ctx):
    # musl builds -nostdinc but still needs the kernel uapi (asm/ syscall and
    # signal numbers, some linux/ headers); gcc 4.7 honors C_INCLUDE_PATH.
    return [setenv("C_INCLUDE_PATH", ctx.dep("linux-headers").prefix + "/include")]

def edit(ctx):
    # system()/popen() execv a hardcoded "/bin/sh"; repoint at the store shell.
    # Absolute path is fine: bootstrap-only libc, never relocated.
    return [replace_bin_sh(ctx, ["src/process/system.c", "src/stdio/popen.c"])]

def install(ctx):
    binutils = ctx.dep("binutils-boot0").prefix
    # gcc and binutils triples differ, so pin AR/RANLIB rather than relying on
    # musl's CROSS_COMPILE-derived names.
    tools = ["AR=" + binutils + "/bin/ar", "RANLIB=" + binutils + "/bin/ranlib"]
    return [
        # "./configure" (not "configure"): musl derives srcdir from ${0%/configure},
        # which is still "." when invoked as `$sh ./configure`.
        run(ctx.sh, "./configure", "CC=gcc", "--target=" + triple(ctx, "musl"),
            "--prefix=" + ctx.prefix, "--syslibdir=" + ctx.prefix + "/lib", "--disable-shared"),
        run("make", ctx.makejobs, tools),
        run("make", "install", tools),
        run("test", "-f", ctx.prefix + "/lib/libc.a"),
        run("test", "-f", ctx.prefix + "/lib/crt1.o"),
        # Merge the kernel uapi headers into the sysroot so C++ compiles find linux/*,
        # asm/* (C_INCLUDE_PATH covers only C, but libstdc++'s random.cc needs
        # <linux/types.h>). Disjoint dirs, so no clash with musl's.
        copy(ctx.dep("linux-headers").prefix + "/include/.", ctx.prefix + "/include/", recursive = True),
    ]
