# SPDX-License-Identifier: MIT

"""Linux kernel uapi headers (asm/, asm-generic/, linux/, ...), sanitized with
'make headers_install' -- no kernel compile"""

load("//build_systems/lib.star", "kernel_arch")

homepage = "https://www.kernel.org/"
license("GPL-2.0-only")

version(
    "6.9.1",
    sha256 = "01b414ba98fd189ecd544435caf3860ae2a790e3ec48f5aa70fdf42dc4c5c04a",
    url = "https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.9.1.tar.xz",
)

build_system("generic")

# Built by the chain's GCC 4.7 (HOSTCC compiles scripts/basic/fixdep and
# scripts/unifdef). make = gmake (musl-linked, drives the jobserver).
depends_on("gcc-boot0", type = "build")
depends_on("gmake", type = "build")
depends_on("sed@4.9-musl", type = "build")
depends_on("xz@5.2.5-musl", type = "build")
depends_on("grep-boot", type = "build")
depends_on("gawk-boot", type = "build")
depends_on("diffutils", type = "build")
depends_on("findutils", type = "build")
depends_on("dash@0.5.12", type = "build")

def install(ctx):
    # Linux ARCH uses its own arch names: aarch64 -> arm64 (selects the arm64
    # asm/ uapi), amd64 -> x86_64.
    # 'headers' runs the copy+unifdef pass (strips __KERNEL__ blocks,
    # __force/__user) into usr/include -- no .config needed, the stage is a fresh
    # tree. Uses `headers` + manual copy rather than `headers_install`.
    return [
        run("make", "headers", "ARCH=" + kernel_arch(ctx), "HOSTCC=gcc"),
        mkdir(ctx.prefix + "/include"),
        copy("usr/include/.", ctx.prefix + "/include/", recursive = True),
    ]
