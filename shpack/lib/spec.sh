# SPDX-License-Identifier: MIT
#
# spec.sh -- spec naming, and the file helpers the shell side shares.
#
# A spec names a package at a concrete version. On the command line and in
# depends_on it is written "name" or "name@version"; once resolved it becomes
# the node id "name-version". Because versions may themselves contain dashes
# (gcc-4.7-2013.11 is name "gcc" at version "4.7-2013.11"), ids are never split
# back into parts: the name and version of a node are stored separately in its
# state dir.
#
# Every concretized node gets Spack's DAG hash (lib/concretize.star), which
# names its store prefix $STORE/linux-<target>/<name>-<version>-<hash>.
# host.files in star lists the package files as walk_files below does.

# walk_files DIR [REL] -> print the relative paths of all regular files under
# DIR, depth-first. Glob expansion order is deterministic (sorted), which is
# what makes the recipe-content part of the hash canonical. Dotfiles are not
# package material and are skipped.
walk_files() {
    local f rel
    for f in "$1"/*; do
        if [ ! -e "$f" ]; then continue; fi
        rel="${2:+$2/}${f##*/}"
        if [ -d "$f" ]; then
            walk_files "$f" "$rel"
        else
            printf '%s\n' "$rel"
        fi
    done
}
