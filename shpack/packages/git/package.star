# SPDX-License-Identifier: MIT

load("//build_systems/lib.star", "triple")

package(
    description = "Git 2.53.0 -- distributed version control system. Built "
                  + "HTTPS-capable (curl + openssl + nghttp2) at the gcc-16 layer, "
                  + "without manpages or NLS. shpack has no autoconf, so the build runs "
                  + "git's shipped ./configure.",
    homepage = "https://git-scm.com",
    license = "GPL-2.0-only",
)

version(
    "2.53.0",
    sha256 = "429dc0f5fe5f14109930cdbbb588c5d6ef5b8528910f0d738040744bebdc6275",
    url = "https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.53.0.tar.gz",
)

build_system("autotools")

# HTTPS transport: curl + openssl + nghttp2 (via curl). expat = dumb-HTTP push;
# pcre2 = `git grep -P`; zlib-ng = pack codec; perl drives script generation.
# coreutils: templates/Makefile's boilerplate rule ends with `date >$@`, which
# would exit-127 without date; the timestamp only lands in a make stamp.
depends_on(
    "compiler-wrapper",
    "curl",
    "openssl",
    "zlib-ng",
    "expat",
    "pcre2",
    "perl",
    "gmake",
    "coreutils",
)
depends_on("dash")

def edit(ctx):
    # glibc 2.43 provides arc4random, so use it as git's CSPRNG. config.mak is
    # read by git's Makefile after configure.
    return [write_file("config.mak", "CSPRNG_METHOD=arc4random\n")]

def configure_args(ctx):
    # Explicit glibc triple (no uname/config.guess). Dep prefixes via --with-*
    # (no auto-detection); the wrapper supplies the -I/-L/-rpath.
    t = triple(ctx)
    return [
        "CC=gcc",
        "--build=" + t,
        "--host=" + t,
        "--with-curl=" + ctx.dep("curl").prefix,
        "--with-openssl=" + ctx.dep("openssl").prefix,
        "--with-zlib=" + ctx.dep("zlib-ng").prefix,
        "--with-expat=" + ctx.dep("expat").prefix,
        "--with-libpcre2=" + ctx.dep("pcre2").prefix,
        "--with-perl=" + ctx.dep("perl").prefix + "/bin/perl",
        "--without-tcltk",
    ]

# NO_GETTEXT: built ~nls (no gettext in the store). NO_TCLTK: no gitk/git-gui.
# SHELL_PATH bakes the store shell into git's generated scripts and into git's
# compiled-in default shell (the sandbox has no host /bin/sh).
def build_args(ctx):
    return [
        "NO_GETTEXT=1",
        "NO_TCLTK=1",
        "SHELL_PATH=" + ctx.sh,
    ]

def install_targets(ctx):
    return [
        "install",
        "NO_GETTEXT=1",
        "NO_TCLTK=1",
        "SHELL_PATH=" + ctx.sh,
    ]
