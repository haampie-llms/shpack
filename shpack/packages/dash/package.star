# SPDX-License-Identifier: MIT

load("//build_systems/autotools.star", autotools_install = "install")
load("//build_systems/lib.star", "triple")

package(
    description = "dash 0.5.13.4 -- a small POSIX /bin/sh. Built fully static against "
                  + "glibc so the resulting binary has no shared-library dependency and "
                  + "an empty runtime closure.",
    homepage = "http://gondor.apana.org.au/~herbert/dash/",
    license = "BSD-3-Clause",
)

version(
    "0.5.13.4",
    sha256 = "d10dfd41cda59165560db39ca915c2c4a7636fff04281d8d2df77ad92c753e2b",
    url = "http://gondor.apana.org.au/~herbert/dash/files/dash-0.5.13.4.tar.gz",
)

build_system("autotools")

# Built by gcc-16-boot0 directly (no wrapper): a static link needs only glibc's
# startfiles + libc.a via -B, not the dynamic loader/rpath a wrapper injects.
# glibc here is the throwaway 2.43-boot (the final 2.43 depends on this dash, so
# linking it against 2.43 would be a cycle). binutils provides as/ld.
depends_on("gcc-boot", "glibc@2.43-boot", "binutils@2.46.0-musl", "gmake")
depends_on("dash@0.5.12")

def configure_args(ctx):
    t = triple(ctx)
    cc = ctx.dep("gcc-boot").prefix + "/bin/gcc"
    gl = ctx.dep("glibc").prefix
    # Static: -B finds crt*.o + libc.a, -I glibc's headers. No NLS/printf-builtin
    # frills -- this is a build-time /bin/sh, not a user shell.
    return [
        "CC=%s -B%s/lib -I%s/include -static" % (cc, gl, gl),
        "CFLAGS=-g -O2 " + ctx.file_prefix_map,
        "--build=" + t,
        "--host=" + t,
        "--enable-static",
    ]

def install(ctx):
    # dash installs only bin/dash; consumers ($sh, /bin/sh) expect bin/sh too.
    return autotools_install(ctx) + [
        hardlink(ctx.prefix + "/bin/dash", ctx.prefix + "/bin/sh", force = True),
    ]
