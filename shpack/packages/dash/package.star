# SPDX-License-Identifier: MIT

"""dash 0.5.13.4 -- a small POSIX /bin/sh. Built fully static against glibc so
the resulting binary has no shared-library dependency and an empty runtime
closure."""

load("//build_systems/autotools.star", autotools_install = "install")
load("//build_systems/lib.star", "triple")

homepage = "http://gondor.apana.org.au/~herbert/dash/"
license("BSD-3-Clause")

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
depends_on("gcc-boot2", type = "build")
depends_on("glibc@2.43-boot")
depends_on("binutils-boot1", type = "build")
depends_on("gmake", type = "build")
# Built with the bootstrap dash; `dash-boot` names that kaem-phase prefix,
# since a package cannot depend on (another version of) itself in Spack.
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("dash-boot", type = "build")

def configure_args(ctx):
    t = triple(ctx)
    cc = ctx.dep("gcc-boot2").prefix + "/bin/gcc"
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
