#!/bin/bash
# Builds the package from this checkout, with the changes that are not
# committed yet, instead of the official git source: to try a change on this
# computer before it is published. Nothing is downloaded. The revision in
# "big-storage-rescue --version" then ends in -dirty when something was not
# committed.
#
# Usage: pkgbuild/build-local.sh [MAKEPKG OPTIONS]
#   pkgbuild/build-local.sh          builds pkgbuild/big-storage-rescue-*.pkg.tar*
#   pkgbuild/build-local.sh -si      also installs it (asks for the password)

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bsr-pkg.XXXXXX")"
trap 'rm -rf -- "${WORK:?}"' EXIT

# The source as makepkg would clone it, then what changed since the last commit
git clone -q --no-hardlinks -- "$REPO" "$WORK/src/big-storage-rescue"
cd "$REPO"
{ git ls-files -z --modified; git ls-files -z --others --exclude-standard; } |
    while IFS= read -r -d '' f; do
        [ -e "$f" ] && cp --parents -a -t "$WORK/src/big-storage-rescue" -- "$f"
    done
git ls-files -z --deleted | while IFS= read -r -d '' f; do
    rm -f -- "$WORK/src/big-storage-rescue/$f"
done

cp -- "$HERE/PKGBUILD" "$HERE/big-storage-rescue.install" "$WORK/"
cd "$WORK"
# -e: use the source prepared above (makepkg would clone the official one).
# BUILDDIR is the build folder itself, whatever makepkg.conf says
BUILDDIR="$WORK" PKGDEST="${PKGDEST:-$HERE}" makepkg -e -f "$@"
