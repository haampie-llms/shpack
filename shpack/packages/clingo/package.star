# SPDX-License-Identifier: MIT

"""clingo (potassco) @spack branch -- the ASP grounder/solver Spack uses as its
concretizer. Built with the CPython C-API bindings (no cffi/libffi), the same
configuration as Spack's clingo-bootstrap@spack."""

load("//build_systems/lib.star", "triple")

homepage = "https://potassco.org/clingo/"
license("MIT")

# The @spack git commit, which builds pyclingo without cffi. GitHub archives omit
# submodule contents, so clasp and its nested libpotassco come as resources,
# relocated in edit().
version(
    "5.5.0-spack",
    sha256 = "7818eef2296c17ad38a57a77f7925c8df41744c4e736ab81042df95c1330f43b",
    url = "https://github.com/potassco/clingo/archive/2a025667090d71b2c9dce60fe924feb6bde8f667.tar.gz",
    fname = "clingo-2a025667.tar.gz",
)
resource(
    url = "https://github.com/potassco/clasp/archive/b089aa1509511ab403c0b9abd0d13eb9e873af44.tar.gz",
    sha256 = "ab2ac6601292619f94831065ee5c009f3168e14be52a65df7b9abdc20a1fc33f",
    fname = "clasp-b089aa15.tar.gz",
)
resource(
    url = "https://github.com/potassco/libpotassco/archive/2f9fb7ca2c202f1b47643aa414054f2f4f9c1821.tar.gz",
    sha256 = "41eb8b7d87ecea48392de4ada455cda179cbd62fd63496355dea87e1e44b599f",
    fname = "libpotassco-2f9fb7ca.tar.gz",
)

build_system("generic")

# bison/re2c generate the gringo parser/lexer; cmake drives the build; cpython
# provides headers + libpython for the bindings.
depends_on("compiler-wrapper", type = "build")
depends_on("cpython")
depends_on("re2c", type = "build")
depends_on("cmake", type = "build")
depends_on("bison", type = "build")
depends_on("gmake", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk@5.3.1", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("tar@1.35-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("dash", type = "build")

def edit(ctx):
    # do_stage cd'd into whichever flat dir sorted first; work from clingo's.
    return [
        chdir(ctx.stage_dir + "/clingo-*"),
        # Reconstruct the submodule tree the @spack commit pins.
        remove("clasp", recursive = True),
        move("../clasp-*/", "clasp"),
        remove("clasp/libpotassco", recursive = True),
        move("../libpotassco-*/", "clasp/libpotassco"),
        # Drop PyEval_ThreadsInitialized/PyEval_InitThreads (removed in Python 3.9).
        substitute("libpyclingo/pyclingo.cc",
                   "if (!PyEval_ThreadsInitialized()) { PyEval_InitThreads(); }", ""),
        # Doxygen can't be disabled via a -D; neutralize the lookup (as Spack does).
        substitute(["clasp/CMakeLists.txt", "clasp/libpotassco/CMakeLists.txt"],
                   "find_package(Doxygen)", 'message("Doxygen disabled")'),
    ]

def install(ctx):
    py = ctx.dep("cpython").prefix
    wrapper = ctx.dep("compiler-wrapper").prefix

    # Pass PYCLINGO_INSTALL_DIR + PYCLINGO_SUFFIX (EXT_SUFFIX) so cmake never falls
    # back to cmake/python-site.py, which imports distutils (gone in Python 3.12+).
    # EXT_SUFFIX is fixed by the CPython version and the platform triplet.
    suffix = ".cpython-314-" + triple(ctx) + ".so"

    return [
        setenv("CC", wrapper + "/bin/cc"),
        setenv("CXX", wrapper + "/bin/c++"),
        prepend_path("PATH", ctx.dep("bison").prefix + "/bin"),
        prepend_path("PATH", ctx.dep("re2c").prefix + "/bin"),
        prepend_path("PATH", ctx.dep("cmake").prefix + "/bin"),
        mkdir("build"),
        chdir("build"),
        # PY_SHARED=OFF: a self-contained _clingo*.so in clingo's own site-packages.
        # Pin libdir: GNUInstallDirs picks lib vs lib64 from EXISTS /etc/debian_version,
        # which leaks the host fs (present on Ubuntu, absent in the chroot rootfs) and
        # made libclingo.so + its rpath differ between build environments.
        # The wrapper injects deps' rpaths CMake doesn't track, so its install-time
        # rpath edit still fires; NO_BUILTIN_CHRPATH makes it a clean relink instead of
        # an in-place zero-fill that pads .dynstr by a build-dir-dependent amount.
        run(
            "cmake",
            "..",
            "-DCMAKE_INSTALL_PREFIX=" + ctx.prefix,
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON",
            "-DCMAKE_NO_BUILTIN_CHRPATH=ON",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCLINGO_BUILD_WITH_PYTHON=ON",
            "-DCLINGO_REQUIRE_PYTHON=ON",
            "-DCLINGO_BUILD_PY_SHARED=OFF",
            "-DCLINGO_BUILD_APPS=OFF",
            "-DCLINGO_BUILD_TESTS=OFF",
            "-DCLASP_BUILD_WITH_THREADS=ON",
            "-DPYCLINGO_USER_INSTALL=OFF",
            "-DPYCLINGO_USE_INSTALL_PREFIX=ON",
            "-DPYCLINGO_INSTALL_DIR=" + ctx.prefix + "/lib/python3.14/site-packages",
            "-DPYCLINGO_SUFFIX=" + suffix,
            "-DPython_ROOT_DIR=" + py,
            "-DPython_EXECUTABLE=" + py + "/bin/python3",
            "-DPython3_EXECUTABLE=" + py + "/bin/python3",
        ),
        run("make", ctx.makejobs),
        run("make", "install"),
    ]
