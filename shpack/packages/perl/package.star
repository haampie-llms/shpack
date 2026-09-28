# SPDX-License-Identifier: MIT

"""Perl 5.40.2 -- build dependency of OpenSSL (its Configure and build
generators are Perl). Core interpreter only; the optional DB/gdbm extensions
Spack's perl pulls in aren't needed here."""

load("//build_systems/lib.star", "cpu", "uname_shim")

homepage = "https://www.perl.org/"
license("Artistic-1.0-Perl OR GPL-1.0-or-later")

version(
    "5.40.2",
    sha256 = "10d4647cfbb543a7f9ae3e5f6851ec49305232ea7621aed24c7cfbb0bef4b70d",
    url = "https://www.cpan.org/src/5.0/perl-5.40.2.tar.gz",
)

build_system("generic")

# Configure leans on awk and grep, neither in the bootstrap base PATH, and probes
# for `comm` (kit-completeness check) -- coreutils supplies it.
depends_on("compiler-wrapper", type = "build")
depends_on("coreutils", type = "build")
depends_on("gawk", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gmake", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("dash", type = "build")

def edit(ctx):
    # `cat`/`pwd` from the coreutils dep: the first on this build's PATH.
    storecat = ctx.dep("coreutils").prefix + "/bin/cat"
    storepwd = ctx.dep("coreutils").prefix + "/bin/pwd"
    glibc = ctx.dep("glibc").prefix
    config_over = "\n".join([
        "cf_time='Thu Jan  1 00:00:00 UTC 1970'",
        "groupcat=''",
        "hostcat=''",
        "passcat=''",
        "installusrbinperl='undef'",
        "pager='%s'" % storecat,
        "sysman=''",
        "myarchname='%s-linux'" % cpu(ctx),
        "glibpth='%s/lib'" % glibc,
        "plibpth=''",
        "libpth='%s/lib'" % glibc,
        "libspath=' %s/lib'" % glibc,
        "libc='%s/lib/libc.so.6'" % glibc,
        "incpth=`echo \" $incpth \" | sed 's| /usr/local/include||g'`",
        "ccincpth=`echo \" $ccincpth \" | sed 's| /usr/local/include||g'`",
        "",
    ])
    # Perl's Configure (and myconfig) call `uname`, absent in the sandbox.
    return uname_shim(ctx) + [
        # Configure's basic-shell search takes the host /bin/sh whenever the file is
        # present, which the sandbox denies executing. Point it at the store shell;
        # the $startsh it derives then flows into every helper script it generates
        # (patch-shebangs, acting only on existing #! lines, can't reach those).
        substitute("Configure", "xxx='/bin/sh'", "xxx='%s'" % ctx.sh),
        # Configure's shebang test runs "#!$xcat", but xcat defaults to the host
        # /bin/cat, which the sandbox denies; the test then silently fails and
        # Configure falls back to unexecutable ': use' scripts. Point xcat at store cat.
        substitute("Configure", "xcat=/bin/cat", "xcat=" + storecat),
        substitute("Configure", "xcat=/usr/bin/cat", "xcat=" + storecat),
        # The Errno extension scans <errno.h>, hardcoding "$sysroot/usr/include"
        # first; it finds the host errno.h (unreadable in the sandbox) and dies.
        # Point it at the store glibc headers.
        substitute("ext/Errno/Errno_pm.PL", '"$sysroot/usr/include"', '"%s/include"' % glibc),
        # Cwd.pm shells out to a hardcoded /bin/pwd (denied), so cwd() comes back
        # empty and MakeMaker dies. Repoint the first candidate at the store pwd.
        substitute("dist/PathTools/Cwd.pm", "'/bin/pwd'", "'%s'" % storepwd),
        # config.over wins over probing (sourced last): pin the wall-clock stamp and
        # the host-FS probes that diverge between host and hermetic chroot. Lib paths
        # -> store glibc; pager -> in-closure cat (no pager packaged; never invoked).
        write_file("config.over", config_over),
    ]

def install(ctx):
    gcc = ctx.dep("compiler-wrapper").prefix
    glibc = ctx.dep("glibc").prefix
    return [
        # -des = non-interactive defaults. No /usr/include or /usr/lib, so point the
        # include/lib probes at the glibc store prefix; -Dosname=linux forces
        # hints/linux.sh (the missing uname would otherwise leave osname empty).
        run(
            ctx.sh,
            "./Configure",
            "-des",
            "-Dprefix=" + ctx.prefix,
            "-Dcc=" + gcc + "/bin/gcc",
            "-Dld=" + gcc + "/bin/gcc",
            "-Dosname=linux",
            "-Darchname=%s-linux" % cpu(ctx),
            "-Dusrinc=" + glibc + "/include",
            "-Dlibpth=" + glibc + "/lib",
            "-Dlocincpth= ",
            "-Dloclibpth= ",
            "-Dman1dir=none",
            "-Dman3dir=none",
            "-Dusenm=false",
        ),
        run("make", ctx.makejobs),
        run("make", "install"),
    ]
