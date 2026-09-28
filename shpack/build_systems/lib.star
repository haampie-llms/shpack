# SPDX-License-Identifier: MIT
#
# Helpers shared by the build systems and by recipes. Pure functions of the
# build context; load them with
#
#     load("//build_systems/lib.star", "triple")

def hook(ctx, name, default):
    """Result of the recipe's NAME(ctx) hook, or default if it has none."""
    f = getattr(ctx.pkg, name, None)
    return f(ctx) if f else default

_CPU = {"amd64": "x86_64", "aarch64": "aarch64"}

def cpu(ctx):
    """The GNU cpu name of the target: x86_64 or aarch64."""
    return _CPU[ctx.arch]

def triple(ctx, libc = "gnu", vendor = None):
    """The target triple, e.g. x86_64-linux-gnu. libc is gnu or musl; pass
    vendor = "unknown" for the x86_64-unknown-linux-musl form the older
    config.sub vintages in the early chain expect."""
    return cpu(ctx) + "-" + (vendor + "-" if vendor else "") + "linux-" + libc

_LD_SO = {"amd64": "ld-linux-x86-64.so.2", "aarch64": "ld-linux-aarch64.so.1"}

def ld_so(ctx):
    """File name of glibc's dynamic loader for the target."""
    return _LD_SO[ctx.arch]

_KERNEL_ARCH = {"amd64": "x86_64", "aarch64": "arm64"}

def kernel_arch(ctx):
    """The Linux kernel's ARCH= name for the target."""
    return _KERNEL_ARCH[ctx.arch]

def replace_bin_sh(ctx, files):
    """Repoint the literal /bin/sh some sources execv/system/popen at the
    build shell. Unlike patch-shebangs (which rewrites #! lines), these are
    string literals in the program text. Belongs in edit()."""
    return substitute(files, "/bin/sh", ctx.sh)

def uname_shim(ctx):
    """Actions putting a minimal `uname` for the target first on PATH. There is
    no uname in the sandbox, and several configure scripts and Makefiles ask
    it for the system (perl's Configure, cpython's configure, zstd's soname
    logic). Belongs in edit(); the PATH change persists through the build."""
    shimbin = ctx.stage_dir + "/shimbin"
    script = "\n".join([
        "#!" + ctx.sh,
        'case "$1" in',
        "  -s) echo Linux ;;",
        "  -r) echo 6.9.1 ;;",
        "  -m|-p|-i) echo %s ;;" % cpu(ctx),
        "  -n) echo shpack ;;",
        "  -o) echo GNU/Linux ;;",
        '  -a) echo "Linux shpack 6.9.1 #1 SMP %s GNU/Linux" ;;' % cpu(ctx),
        "  *)  echo Linux ;;",
        "esac",
        "",
    ])
    return [
        mkdir(shimbin),
        write_file(shimbin + "/uname", script, mode = "755"),
        prepend_path("PATH", shimbin),
    ]
