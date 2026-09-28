#!/bin/sh
# SPDX-License-Identifier: MIT
#
# corpus.sh OUTDIR -- the canonical JSON of every shpack recipe, for comparing
# evaluators: the directive record of each package, and its plan for every
# version and arch against a fixed synthetic build context. Two backends
# implement star/PROTOCOL.md identically when
#
#     STAR=star-a sh corpus.sh a && STAR=star-b sh corpus.sh b && diff -r a b
#
# shows nothing. STAR defaults to `star` on PATH.

set -e
out=${1:?usage: corpus.sh OUTDIR}
here=$(cd "$(dirname "$0")" && pwd)
root=$here/../../shpack
repo=$root/packages
STAR=${STAR:-star}
mkdir -p "$out"

# every package name, for ctx.deps (the synthetic closure is everything)
deps=$(for d in "$repo"/*/; do n=${d%/}; n=${n##*/}; printf '"%s": "/store/%s-0000000", ' "$n" "$n"; done)

for d in "$repo"/*/; do
    name=${d%/}
    name=${name##*/}
    "$STAR" recipe --repo "$repo" --root "$root" --format json "$name" > "$out/$name.recipe.json"
    files=$(cd "$d" && find . -type f ! -name '.*' | sed 's|^\./||' | LC_ALL=C sort |
            sed 's/.*/"&"/' | paste -sd, -)
    "$STAR" recipe --repo "$repo" --root "$root" --format shpack "$name" |
    awk '/^## /{s=$2; next} s=="versions"{print $1}' |
    while read -r version; do
        for arch in amd64 aarch64; do
            stage=/var/stage/$name-$version
            cat > "$out/ctx.star" <<EOC
ctx = {
    "name": "$name", "version": "$version", "id": "$name-$version", "arch": "$arch",
    "prefix": "/store/$name-$version-0000000", "sh": "/store/dash/bin/sh",
    "stage_dir": "$stage", "source_dir": "$stage/src", "package_dir": "$repo/$name",
    "jobs": 4, "makejobs": [],
    "file_prefix_map": "-ffile-prefix-map=$stage=.",
    "debug_prefix_map": "-fdebug-prefix-map=$stage=.",
    "package_files": [$files],
    "deps": {$deps},
}
EOC
            "$STAR" plan --repo "$repo" --root "$root" --ctx "$out/ctx.star" --format json \
                "$name" > "$out/$name@$version.$arch.plan.json"
        done
    done
done
rm -f "$out/ctx.star"
ls "$out" | wc -l | sed 's/^ */corpus: /; s/$/ files/'
