#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets, helpers called through check()
# Big-Mount and Big Storage Rescue side by side, through real pacman
# transactions in scratch roots (fakeroot pacman --root --dbpath): nothing is
# installed on this system. Scriptlets are not run; the pacman hook of
# big-mount (systemctl enable) cannot run either, because pacman needs a real
# chroot for it and fakeroot cannot give one (it fails with "Operation not
# permitted", harmlessly).
#
# Usage: tests/coexistence-check.sh BIG-MOUNT-2.6.pkg.tar BIG-MOUNT-3.pkg.tar BIG-STORAGE-RESCUE.pkg.tar
#   Build the packages with makepkg from the PKGBUILD of each repository
#   (docs/14-packaging.md). Needs fakeroot.
[ "$#" -eq 3 ] || { sed -n '3,12p' "$0"; exit 2; }
OLD="$(realpath "$1")" NEW="$(realpath "$2")" BSR="$(realpath "$3")"
S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT
PASS=0 FAIL=0
check() { local d="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "  ✓ $d"; else FAIL=$((FAIL+1)); echo "  ✗ $d"; fi; }

root() { # fresh scratch root
    R="$S/root-$1"; rm -rf "$R"; mkdir -p "$R/var/lib/pacman" "$R/var/cache/pacman" "$R/hooks" "$R/etc"
}
# -dd: no dependency check at all, the scratch root has no system in it
pm() {
    fakeroot pacman --root "$R" --dbpath "$R/var/lib/pacman" --cachedir "$R/var/cache/pacman" \
        --logfile "$R/pacman.log" --hookdir "$R/hooks" --noscriptlet --nodeps --nodeps --noconfirm "$@" > "$R/out" 2>&1
}
owns() { [ -e "$R$2" ] && fakeroot pacman --root "$R" --dbpath "$R/var/lib/pacman" -Qqo "$R$2" 2>/dev/null | grep -qx "$1"; }

echo "1. only Big-Mount 3.0"
root 1; pm -U "$NEW"; check "installs" grep -q 'big-mount' <(fakeroot pacman --root "$R" --dbpath "$R/var/lib/pacman" -Q)
check "no application, no Dolphin menu" bash -c '[ ! -e "$1/usr/share/applications" ] && [ ! -e "$1/usr/share/kio" ]' _ "$R"

echo "2. only Big Storage Rescue"
root 2; pm -U "$BSR"; check "installs" grep -q 'big-storage-rescue' <(fakeroot pacman --root "$R" --dbpath "$R/var/lib/pacman" -Q)
check "nothing at boot: no unit, no hook, nothing in /etc" bash -c '[ ! -e "$1/usr/lib/systemd" ] && [ ! -e "$1/usr/share/libalpm" ] && [ -z "$(ls -A "$1/etc")" ]' _ "$R"

echo "3. both, in one transaction"
root 3; pm -U "$NEW" "$BSR"; check "no file conflict" bash -c '! grep -qi conflict "$1/out" && [ "$(fakeroot pacman --root "$1" --dbpath "$1/var/lib/pacman" -Qq | wc -l)" = 2 ]' _ "$R"

echo "4. Big Storage Rescue on a system with Big-Mount 2.6, then Big-Mount updated alone"
root 4; pm -U "$OLD"; check "2.6 installed" owns big-mount /usr/lib/big-mount/drive-gui.py
pm -U "$BSR"; check "Big Storage Rescue beside 2.6: no conflict" bash -c '! grep -qi conflict "$1/out" && [ -e "$1/usr/bin/big-storage-rescue" ]' _ "$R"
check "  ... the files of 2.6 are still its own" owns big-mount /usr/lib/big-mount/drive-gui.py
pm -U "$NEW"; check "update of big-mount alone: no conflict" bash -c '! grep -qi conflict "$1/out"' _ "$R"
check "  ... the files of 2.x are gone" bash -c '[ ! -e "$1/usr/lib/big-mount/drive-gui.py" ] && [ ! -e "$1/usr/lib/big-mount/gui" ] && [ ! -e "$1/usr/share/applications/big-mount.desktop" ]' _ "$R"
check "  ... the configuration is kept (backup=)" test -e "$R/etc/big-mount.conf"
check "  ... Big Storage Rescue is untouched" owns big-storage-rescue /usr/lib/big-storage-rescue/drive-copy.sh

echo "5. both updated together, from 2.6"
root 5; pm -U "$OLD"; pm -U "$NEW" "$BSR"; check "no conflict" bash -c '! grep -qi conflict "$1/out" && [ "$(fakeroot pacman --root "$1" --dbpath "$1/var/lib/pacman" -Qq | wc -l)" = 2 ]' _ "$R"

echo "6. removing one leaves the other"
root 6; pm -U "$NEW" "$BSR"; pm -R big-storage-rescue
check "without Big Storage Rescue, Big-Mount stays whole" bash -c '[ -e "$1/usr/bin/bigmount" ] && [ -e "$1/usr/lib/big-mount/cli.sh" ] && [ ! -e "$1/usr/bin/big-storage-rescue" ]' _ "$R"
root 7; pm -U "$NEW" "$BSR"; pm -R big-mount
check "without Big-Mount, Big Storage Rescue stays whole" bash -c '[ -e "$1/usr/bin/big-storage-rescue" ] && [ -e "$1/usr/lib/big-storage-rescue/cli.sh" ] && [ ! -e "$1/usr/bin/bigmount" ]' _ "$R"

echo "8. the installed programs answer, from the scratch roots"
R="$S/root-3"
check "bigmount --help, from the package" bash -c 'BIGMOUNT_LIB="$1/usr/lib/big-mount" LANGUAGE=C bash "$1/usr/bin/bigmount" --help | grep -q "^Usage: bigmount"' _ "$R"
check "big-storage-rescue --help, from the package" bash -c 'LANGUAGE=C bash "$1/usr/bin/big-storage-rescue" --help | grep -q "^Usage: big-storage-rescue"' _ "$R"
check "bigmount --drive says where it went" bash -c 'LANGUAGE=C bash "$1/usr/bin/bigmount" --drive list 2>&1 | grep -q "Use: big-storage-rescue --cli list"' _ "$R"

echo "coexistence: $PASS passed, $FAIL failed"
exit "$FAIL"
