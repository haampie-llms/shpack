# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "ld_so")

package(
    description = "Thin wrapper making crippled gcc-16-boot0 target glibc 2.43: "
                  + "gcc/g++ scripts that inject glibc's startfiles, loader and rpath. "
                  + "Sourceless shim.",
    homepage = "https://gcc.gnu.org/",
    license = "GPL-3.0-or-later",
)

# Sourceless: no url/sha256 -> nothing to fetch, builds in the stage dir.
version("16.1.0")

build_system("generic")

depends_on("gcc-boot", "glibc", "binutils@2.46.0-musl")
# The gcc/g++ shims are #!$sh scripts, so the clean glibc dash is a runtime dep.
depends_on("dash")

def install(ctx):
    gcc = ctx.dep("gcc-boot").prefix
    glibc = ctx.dep("glibc").prefix
    binutils = ctx.dep("binutils").prefix

    # gcc/g++ wrappers: -B finds crt1.o/crti.o/crtn.o from the new libc;
    # -dynamic-linker points executables at glibc's loader; -rpath finds
    # libc.so.6 at run time. SHPACK_FILE_PREFIX_MAP (set per-build) strips the
    # build dir from __FILE__ for reproducibility.
    wrappers = [
        write_file(
            ctx.prefix + "/bin/" + prog,
            "#!%s\nexec %s -B%s/lib -Wl,-dynamic-linker -Wl,%s -Wl,-rpath -Wl,%s/lib $SHPACK_FILE_PREFIX_MAP \"$@\"\n" %
            (ctx.sh, gcc + "/bin/" + prog, glibc, glibc + "/lib/" + ld_so(ctx), glibc),
            mode = "755",
        )
        for prog in ["gcc", "g++"]
    ]

    # Plain-named binutils tools so configure/make find as/ld/ar etc.
    tools = ["ar", "as", "ld", "nm", "objcopy", "objdump", "ranlib", "readelf", "strip"]
    return [mkdir(ctx.prefix + "/bin")] + wrappers + [
        symlink_each([binutils + "/bin/" + t for t in tools], ctx.prefix + "/bin", if_missing = True),
    ]
