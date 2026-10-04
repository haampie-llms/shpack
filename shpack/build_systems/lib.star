# SPDX-License-Identifier: MIT
#
# Helpers shared by the build systems and by recipes. Pure functions of the
# build context; load them with
#
#     load("//build_systems/lib.star", "triple")

def hook(ctx, name, default):
    """The recipe's NAME: a list (Spack's class attribute), or a function of
    ctx returning one (a property); default if the recipe has none."""
    v = getattr(ctx.pkg, name, None)
    if v == None:
        return default
    return v(ctx) if type(v) == "function" else v

def triple(ctx, libc = "gnu", vendor = None):
    """The target triple, e.g. x86_64-linux-gnu. libc is gnu or musl; pass
    vendor = "unknown" for the x86_64-unknown-linux-musl form the older
    config.sub vintages in the early chain expect."""
    return ctx.target + "-" + (vendor + "-" if vendor else "") + "linux-" + libc

_LD_SO = {"x86_64": "ld-linux-x86-64.so.2", "aarch64": "ld-linux-aarch64.so.1"}

def ld_so(ctx):
    """File name of glibc's dynamic loader for the target."""
    return _LD_SO[ctx.target]

_KERNEL_ARCH = {"x86_64": "x86_64", "aarch64": "arm64"}

def kernel_arch(ctx):
    """The Linux kernel's ARCH= name for the target."""
    return _KERNEL_ARCH[ctx.target]

def replace_bin_sh(ctx, files):
    """Repoint the literal /bin/sh some sources execv/system/popen at the
    build shell. Unlike patch-shebangs (which rewrites #! lines), these are
    string literals in the program text. Belongs in edit()."""
    return filter_file("/bin/sh", ctx.sh, files, string = True)

def uname_shim_dir(ctx):
    """Where uname_shim(ctx) puts its uname: for env.prepend_path("PATH", ...)
    in setup_build_environment."""
    return ctx.stage_dir + "/shimbin"

def uname_shim(ctx):
    """Actions writing a minimal `uname` for the target into uname_shim_dir(ctx).
    There is no uname in the sandbox, and several configure scripts and
    Makefiles ask it for the system (perl's Configure, cpython's configure,
    zstd's soname logic). Belongs in edit(); put the directory first on PATH
    in setup_build_environment."""
    script = "\n".join([
        "#!" + ctx.sh,
        'case "$1" in',
        "  -s) echo Linux ;;",
        "  -r) echo 6.9.1 ;;",
        "  -m|-p|-i) echo %s ;;" % ctx.target,
        "  -n) echo shpack ;;",
        "  -o) echo GNU/Linux ;;",
        '  -a) echo "Linux shpack 6.9.1 #1 SMP %s GNU/Linux" ;;' % ctx.target,
        "  *)  echo Linux ;;",
        "esac",
        "",
    ])
    return [
        mkdir(uname_shim_dir(ctx)),
        write_file(uname_shim_dir(ctx) + "/uname", script, mode = "755"),
    ]
