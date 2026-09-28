# SPDX-License-Identifier: MIT

"""CPython 3.14.5 -- the glibc-linked, shared production Python that runs
clingo and Spack. Distinct from the musl 'python' 3.5.9 used only to bootstrap
glibc."""

load("//build_systems/autotools.star", autotools_build = "build")
load("//build_systems/lib.star", "cpu", "replace_bin_sh", "triple", "uname_shim")

homepage = "https://www.python.org/"
license("Python-2.0")

version(
    "3.14.5",
    sha256 = "7e32597b99e5d9a39abed35de4693fa169df3e5850d4c334337ffd6a19a36db6",
    url = "https://www.python.org/ftp/python/3.14.5/Python-3.14.5.tar.xz",
)

build_system("autotools")

# Backs stdlib modules: zlib-ng -> zlib/gzip/zipfile, libffi -> _ctypes, openssl
# -> _ssl, bzip2/xz/zstd -> _bz2/_lzma/_zstd. configure auto-detects each from
# the wrapper's search path.
depends_on("compiler-wrapper", type = "build")
depends_on("zlib-ng")
depends_on("libffi")
depends_on("openssl")
depends_on("bzip2")
depends_on("xz")
depends_on("zstd")
depends_on("gmake", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("dash", type = "build")

def edit(ctx):
    # No uname: configure leaves ac_sys_system empty and LDSHARED falls back to
    # bare `ld`, which chokes on the `-Wl,` flags. Forcing cross to dodge uname
    # won't work (autoconf rejects cross with build==host), so shim a uname that
    # makes configure take the Linux branch.
    return uname_shim(ctx) + [
        # subprocess(shell=True) hardcodes ["/bin/sh", "-c"]; repoint at the store dash.
        replace_bin_sh(ctx, "Lib/subprocess.py"),
        # Suspected fix for an intermittent "build-details.json: Bus error" under the
        # jobserver: the rule runs the interpreter (imports json -> _json.so) but only
        # depends on pybuilddir.txt, so it may race sharedmods writing that .so. Order
        # it after sharedmods. Unconfirmed; cf. cpython#102007.
        filter_file("Makefile.pre.in", "^build-details\\.json: pybuilddir\\.txt$",
                    "build-details.json: pybuilddir.txt sharedmods"),
    ]

def setup_build_environment(ctx):
    wrapper = ctx.dep("compiler-wrapper").prefix
    return [
        setenv("CC", wrapper + "/bin/gcc"),
        setenv("CXX", wrapper + "/bin/g++"),
        # PYTHONHASHSEED=0 pins marshal order of set/frozenset literals in .pyc.
        setenv("PYTHONHASHSEED", "0"),
        # userbase defaults to $HOME/.local, leaking the per-build scratch path into
        # _sysconfig_vars json; pin it (honored since build() strips -E from
        # PYTHON_FOR_BUILD). The live interpreter still recomputes it from real $HOME.
        setenv("PYTHONUSERBASE", "/homeless-shelter"),
        setenv("_PYTHON_HOST_PLATFORM", "linux-" + cpu(ctx)),
    ]

def configure_args(ctx):
    # Explicit triple (no date/uname for config.guess). --enable-shared installs
    # libpython3.14.so; the interpreter needs an rpath to its own libdir
    # (configure adds none).
    # LIBFFI_CFLAGS/LIBFFI_LIBS wire _ctypes directly (no pkg-config in the store).
    # --with-openssl points _ssl/_hashlib at the store OpenSSL; -rpath=auto bakes
    # its libdir into the modules so libssl/libcrypto resolve without LD_LIBRARY_PATH.
    t = triple(ctx)
    ffi = ctx.dep("libffi").prefix
    ssl = ctx.dep("openssl").prefix
    return [
        "--build=" + t,
        "--host=" + t,
        "--enable-shared",
        "--without-ensurepip",
        "--disable-test-modules",
        "--with-system-ffi",
        "--with-openssl=" + ssl,
        "--with-openssl-rpath=auto",
        "LIBFFI_CFLAGS=-I" + ffi + "/include",
        "LIBFFI_LIBS=-L" + ffi + "/lib -lffi",
        "LDFLAGS=-Wl,-rpath," + ctx.prefix + "/lib",
    ]

def build(ctx):
    # Drop -E so the install's compileall honors PYTHONHASHSEED (env is already
    # clean under env -i); pins set/frozenset marshal order in the .pyc.
    return [
        substitute("Makefile", "PYTHON_FOR_BUILD=./$(BUILDPYTHON) -E", "PYTHON_FOR_BUILD=./$(BUILDPYTHON)"),
    ] + autotools_build(ctx)

def install(ctx):
    lib = ctx.prefix + "/lib/python3.14"
    return [
        # COVERAGE_INFO/RUNSHARED/TESTRUNNER bake the abs build dir into these
        # dev/test-only vars (no configure lever). Scrub before install so compileall
        # bakes the scrubbed bytes into the .pyc.
        substitute("./**/_sysconfigdata_*.py", ctx.stage_dir, "/build"),
        substitute("./**/_sysconfig_vars_*.json", ctx.stage_dir, "/build"),
        # -j1: libainstall races the compileall over the same lib tree, so
        # config-*/__pycache__ is nondeterministic. cf. cpython#102007.
        run("make", "install", "-j1", "COMPILEALL_OPTS=-j%d" % ctx.jobs),
        symlink("python3.14", ctx.prefix + "/bin/python3", if_missing = True),
        remove(lib + "/test", recursive = True),
        # config Makefile has no .pyc; scrub it after install.
        substitute(lib + "/config-3.14*-linux-*/Makefile", ctx.stage_dir, "/build"),
    ]
