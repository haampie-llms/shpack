# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "GNU make 4.4.1: replaces the kaem-built make 3.82 for all heavy " +
                  "downstream builds (fixes 3.82's parallel races; fifo jobserver)",
    homepage = "https://www.gnu.org/software/make/",
    license = "GPL-3.0-or-later",
)

# make 3.82 is a kaem-phase external (etc/externals); this recipe is the
# parallel-safe upgrade and the spec named by SHPACK_BOOTSTRAP_MAKE.
version(
    "4.4.1",
    sha256 = "dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3",
    url = "https://ftpmirror.gnu.org/make/make-4.4.1.tar.gz",
)

build_system("autotools")

depends_on("tcc", "musl@1.1.24", "grep@2.4-musl", "gawk@3.0.4")
depends_on("dash@0.5.12")

def configure_args(ctx):
    # No binutils ar yet and config.guess cannot probe this environment: pin the
    # triple and archiver, and disable what needs tools we lack (guile, nls, load).
    # CFLAGS=-O2 drops autotools' default -g: tcc has no -f*-prefix-map, so -g
    # leaks the build cwd as the stabs comp_dir (see builder.sh).
    t = triple(ctx, "musl", vendor = "unknown")
    return [
        "CC=tcc",
        "LD=tcc",
        "CFLAGS=-O2",
        "AR=tcc -ar",
        "ARFLAGS=cr",
        "--build=" + t,
        "--host=" + t,
        "--disable-dependency-tracking",
        "--disable-nls",
        "--without-guile",
        "--disable-load",
    ]

# No make can build make yet (3.82 is what we replace); use the bundled
# build.sh: shell + tcc only.
def build(ctx):
    return [
        filter_file("build.cfg", "^AR=.*", "AR='tcc -ar'"),
        filter_file("build.cfg", "^ARFLAGS=.*", "ARFLAGS='cr'"),
        run(ctx.sh, "./build.sh"),
        # Sanity: it runs and the fifo jobserver is compiled in.
        run("./make", "--version"),
        sh("./make -p -f /dev/null 2>/dev/null | grep jobserver"),
    ]

def install(ctx):
    return [
        mkdir(ctx.prefix + "/bin"),
        copy("make", ctx.prefix + "/bin/make"),
        symlink("make", ctx.prefix + "/bin/gmake", force = True),
    ]
