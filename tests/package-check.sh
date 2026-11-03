#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets and helpers called through check()
# Packaging checks: runs the package() function of pkgbuild/PKGBUILD against
# this checkout (instead of the official git source) into a scratch dir and
# verifies what would be installed. No root, nothing is installed.
#
# Usage: tests/package-check.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
cd "$REPO" || exit 2

PASS=0 FAIL=0 FAILED=()
check() {
    local msg="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$msg"
    else FAIL=$((FAIL + 1)); FAILED+=("$msg"); printf '  \033[31m✗\033[0m %s\n' "$msg"; fi
}
begin() { echo "— $1"; }
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT

echo "========================================="
echo "Packaging checks"
echo "========================================="

begin "repository hygiene"
artifacts="$(git ls-files | grep -E '(^|/)(tmp-|\.integ\.|\.bench\.|\.pkg\.)|~$|\.orig$|\.rej$|\.swp$|\.pkg\.tar' || true)"
check "no test scratch files or editor leftovers are versioned" test -z "$artifacts"
[ -n "$artifacts" ] && printf '      %s\n' "$artifacts"
binaries_in_tests() {
    local f
    git ls-files tests | while read -r f; do
        if [ -s "$f" ] && ! grep -Iq . "$f"; then echo "$f"; fi
    done
}
check "no binary file is versioned under tests/" test -z "$(binaries_in_tests)"

begin "package() on this checkout"
mkdir -p "$WORK/src/big-storage-rescue" "$WORK/pkg"
git ls-files -z | xargs -0 cp --parents -a -t "$WORK/src/big-storage-rescue" 2>/dev/null
# Files of this change that are not committed yet are part of the package too
git ls-files -z --others --exclude-standard -- big-storage-rescue | xargs -0 -r cp --parents -a -t "$WORK/src/big-storage-rescue" 2>/dev/null
# The copy becomes a repository with one commit at a known time, as makepkg
# sees the clone of the git source
(
    cd "$WORK/src/big-storage-rescue" && git init -q && git add -A &&
        GIT_AUTHOR_DATE="2026-10-25T13:42:07Z" GIT_COMMITTER_DATE="2026-10-25T13:42:07Z" \
        git -c user.name=test -c user.email=test@invalid commit -q -m test
) || check "test repository for the package created" false
# A subshell on purpose: PKGBUILD variables must not leak into this script
# shellcheck disable=SC1091,SC2030
if ! ( srcdir="$WORK/src" pkgdir="$WORK/pkg" pkgname=big-storage-rescue; source pkgbuild/PKGBUILD >/dev/null 2>&1; package ); then
    check "package() runs" false
fi
rev="$(git -C "$WORK/src/big-storage-rescue" rev-parse HEAD)"
check "version file names the exact commit (big-storage-rescue --version)" \
    grep -qx "revision=$rev" "$WORK/pkg/usr/lib/big-storage-rescue/version"
check "  ... its date and the source URL" bash -c 'grep -qx "date=2026-10-25T13:42:07Z" "$1" && grep -qx "source=https://github.com/biglinux/big-storage-rescue" "$1"' _ "$WORK/pkg/usr/lib/big-storage-rescue/version"
check "big-storage-rescue --version of the package shows that commit" \
    bash -c 'BSR_LIB="$1/usr/lib/big-storage-rescue" bash "$1/usr/bin/big-storage-rescue" --version | grep -q "${2:0:12}"' _ "$WORK/pkg" "$rev"
P="$WORK/pkg"
expect=(
    "755 usr/bin/big-storage-rescue"
    "755 usr/lib/big-storage-rescue/bsr-holders"
    "644 usr/lib/big-storage-rescue/cli.sh"
    "644 usr/lib/big-storage-rescue/lib.sh"
    "644 usr/lib/big-storage-rescue/ui.sh"
    "644 usr/lib/big-storage-rescue/doctor.sh"
    "755 usr/lib/big-storage-rescue/bsr-drive-helper"
    "755 usr/lib/big-storage-rescue/bsr-image-helper"
    "644 usr/lib/big-storage-rescue/drive.sh"
    "644 usr/lib/big-storage-rescue/drive-detect.sh"
    "644 usr/lib/big-storage-rescue/drive-diag.sh"
    "644 usr/lib/big-storage-rescue/drive-copy.sh"
    "644 usr/lib/big-storage-rescue/drive-recovery.sh"
    "644 usr/lib/big-storage-rescue/drive-salvage.sh"
    "644 usr/lib/big-storage-rescue/drive-tui.sh"
    "644 usr/lib/big-storage-rescue/migrate.sh"
    "644 usr/lib/big-storage-rescue/system-check.sh"
    "644 usr/lib/big-storage-rescue/app.py"
    "644 usr/lib/big-storage-rescue/dialog.py"
    "644 usr/lib/big-storage-rescue/integrity.py"
    "644 usr/lib/big-storage-rescue/gui/__init__.py"
    "644 usr/lib/big-storage-rescue/gui/about.py"
    "644 usr/lib/big-storage-rescue/gui/actions.py"
    "644 usr/lib/big-storage-rescue/gui/application.py"
    "644 usr/lib/big-storage-rescue/gui/common.py"
    "644 usr/lib/big-storage-rescue/gui/damage_map.py"
    "644 usr/lib/big-storage-rescue/gui/dialogs.py"
    "644 usr/lib/big-storage-rescue/gui/engine.py"
    "644 usr/lib/big-storage-rescue/gui/models.py"
    "644 usr/lib/big-storage-rescue/gui/monitor.py"
    "644 usr/lib/big-storage-rescue/gui/style.css"
    "644 usr/lib/big-storage-rescue/gui/widgets.py"
    "644 usr/lib/big-storage-rescue/gui/window.py"
    "644 usr/lib/big-storage-rescue/gui/pages/__init__.py"
    "644 usr/lib/big-storage-rescue/gui/pages/device.py"
    "644 usr/lib/big-storage-rescue/gui/pages/job.py"
    "644 usr/lib/big-storage-rescue/gui/pages/overview.py"
    "644 usr/lib/big-storage-rescue/gui/pages/rescue.py"
    "644 usr/lib/big-storage-rescue/gui/pages/results.py"
    "644 usr/lib/big-storage-rescue/gui/welcome.py"
    "644 usr/lib/big-storage-rescue/version"
    "644 usr/share/big-storage-rescue/big-storage-rescue-notifier.desktop"
    "644 usr/share/applications/org.biglinux.big-storage-rescue.desktop"
    "644 usr/share/kio/servicemenus/big-storage-rescue.desktop"
    "644 usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy"
    "644 usr/share/icons/hicolor/scalable/apps/big-storage-rescue.svg"
    "644 usr/share/metainfo/org.biglinux.big-storage-rescue.metainfo.xml"
    "644 usr/share/locale/pt_BR/LC_MESSAGES/big-storage-rescue.mo"
)
for e in "${expect[@]}"; do
    mode="${e%% *}" f="${e#* }"
    check "$f ($mode)" bash -c '[ -f "$1/$2" ] && [ "$(stat -c %a "$1/$2")" = "$3" ]' _ "$P" "$f" "$mode"
done
installed="$(cd "$P" && find . -type f | sed 's|^\./||' | sort)"
check "nothing else is installed (no docs, tests, templates, scratch files)" \
    test "$installed" = "$(printf '%s\n' "${expect[@]}" | cut -d' ' -f2 | sort)"
check "it never installs a file of Big-Mount (both packages can be installed)" \
    bash -c '! grep -E "big-mount|bigmount" <<< "$1"' _ "$installed"
check "  ... nor runs at boot: no systemd unit, no pacman hook, nothing in /etc" \
    bash -c '! grep -E "^(etc/|usr/lib/systemd/|usr/share/libalpm/)" <<< "$1"' _ "$installed"
check "every translation in locale/LINGUAS is installed" \
    bash -c 'while read -r l; do [ -f "$1/usr/share/locale/$l/LC_MESSAGES/big-storage-rescue.mo" ] || exit 1; done < locale/LINGUAS' _ "$P"

begin "metadata"
pkginfo="$(source pkgbuild/PKGBUILD 2>/dev/null; printf 'source=%s\n' "${source[*]}"; printf 'depends=%s\n' "${depends[*]}"; printf 'backup=%s\n' "${backup[*]:-}"; printf 'install=%s\n' "${install:-}"; printf 'url=%s\n' "$url")"
check "source is the official repository (biglinux/big-storage-rescue)" grep -q "^source=git+https://github.com/biglinux/big-storage-rescue.git$" <<< "$pkginfo"
check "url matches the source" grep -q "^url=https://github.com/biglinux/big-storage-rescue$" <<< "$pkginfo"
check "install script exists and is valid" bash -c '[ "$1" = "install=big-storage-rescue.install" ] && bash -n pkgbuild/big-storage-rescue.install' _ "$(grep ^install= <<< "$pkginfo")"
check "install script restarts nothing by itself" bash -c '! grep -vE "^\s*(#|echo)" pkgbuild/big-storage-rescue.install | grep -qE "systemctl|kill|mount"' 
check "no configuration file of its own (backup= empty)" grep -qx "backup=" <<< "$pkginfo"
check "it neither replaces nor conflicts with big-mount" \
    bash -c 'source pkgbuild/PKGBUILD 2>/dev/null; [[ " ${replaces[*]:-} ${conflicts[*]:-} ${provides[*]:-} " != *big-mount* ]]'
for d in udisks2 util-linux polkit lsof rsync smartmontools python python-gobject python-cairo gtk4 libadwaita libnotify; do check "depends on $d" grep -qw "$d" <<< "$(grep ^depends= <<< "$pkginfo")"; done
check "  ... libadwaita 1.5 with its epoch (1:), or any version would do" grep -q "libadwaita>=1:1.5" <<< "$(grep ^depends= <<< "$pkginfo")"
check "  ... and nothing of the automount (ntfs-3g, big-mount)" bash -c '[[ $1 != *ntfs-3g* && $1 != *big-mount* ]]' _ "$(grep ^depends= <<< "$pkginfo")"
check "the specialized tools are optional" bash -c 'source pkgbuild/PKGBUILD 2>/dev/null; [[ " ${optdepends[*]} " == *"ddrescue:"* && " ${optdepends[*]} " == *"testdisk:"* && " ${depends[*]} " != *ddrescue* && " ${depends[*]} " != *testdisk* ]]' 

begin "installed files are valid"
check "syntax: every module of the application" python3 -I -c 'import ast,sys; [ast.parse(open(f, encoding="utf-8").read()) for f in sys.argv[1:]]' "$P/usr/lib/big-storage-rescue/app.py" "$P/usr/lib/big-storage-rescue/dialog.py" "$P"/usr/lib/big-storage-rescue/gui/*.py "$P"/usr/lib/big-storage-rescue/gui/pages/*.py
check "the package does not need Qt" bash -c 'source pkgbuild/PKGBUILD 2>/dev/null; [[ " ${depends[*]} ${optdepends[*]} " != *pyside* ]]'
check "dialogs are GTK: no kdialog or zenity, needed or used" bash -c 'source pkgbuild/PKGBUILD 2>/dev/null; [[ " ${depends[*]} ${optdepends[*]} " != *kdialog* && " ${depends[*]} ${optdepends[*]} " != *zenity* ]] && ! grep -rqwE "kdialog|zenity" "$1/usr/lib/big-storage-rescue"' _ "$P"
check "no Markdown file is read at run time" bash -c '! grep -rlE "\.md[\"'"'"' ]" "$1/usr/lib/big-storage-rescue/gui" "$1/usr/lib/big-storage-rescue/app.py"' _ "$P"
if command -v desktop-file-validate >/dev/null; then
    check "launcher .desktop" desktop-file-validate "$P/usr/share/applications/org.biglinux.big-storage-rescue.desktop"
    check "notifier .desktop" desktop-file-validate "$P/usr/share/big-storage-rescue/big-storage-rescue-notifier.desktop"
fi
check "service menu: KIO keys present" bash -c 'grep -q "^Type=Service" "$1" && grep -q "^Actions=" "$1" && grep -q "^MimeType=inode/directory;" "$1"' _ "$P/usr/share/kio/servicemenus/big-storage-rescue.desktop"
command -v xmllint >/dev/null && check "polkit policy is well-formed XML" xmllint --noout "$P/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy"
check "polkit exec.path names the installed helper" grep -q '>/usr/lib/big-storage-rescue/bsr-holders<' "$P/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy"
check "polkit exec.path names the drive helper" grep -q '>/usr/lib/big-storage-rescue/bsr-drive-helper<' "$P/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy"
check "a disk image has its own polkit action, which asks every time" python3 -I -c '
import sys, xml.etree.ElementTree as ET
acts = {a.get("id"): a for a in ET.parse(sys.argv[1]).getroot().iter("action")}
a = acts["org.biglinux.big-storage-rescue.image"]
ann = {x.get("key"): x.text for x in a.iter("annotate")}
ok = ann.get("org.freedesktop.policykit.exec.path") == "/usr/lib/big-storage-rescue/bsr-image-helper"
sys.exit(not (ok and all(a.find("defaults/" + k).text == "auth_admin" for k in ("allow_any", "allow_inactive", "allow_active"))))' "$P/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy"
# pkexec takes the first action that matches, in no fixed order: one path, one action
check "  ... no two actions share a program" python3 -I -c '
import sys, xml.etree.ElementTree as ET
paths = [x.text for x in ET.parse(sys.argv[1]).getroot().iter("annotate") if x.get("key") == "org.freedesktop.policykit.exec.path"]
sys.exit(len(paths) != len(set(paths)))' "$P/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy"
check "  ... and bsr-image-helper starts only that verb" bash -c 'grep -qx "exec /usr/lib/big-storage-rescue/bsr-drive-helper image \"\$@\"" "$1"' _ "$P/usr/lib/big-storage-rescue/bsr-image-helper"
command -v xmllint >/dev/null && check "icon is a well-formed SVG" xmllint --noout "$P/usr/share/icons/hicolor/scalable/apps/big-storage-rescue.svg"
check "translation catalog loads" msgunfmt -o /dev/null "$P/usr/share/locale/pt_BR/LC_MESSAGES/big-storage-rescue.mo"
if command -v appstreamcli >/dev/null; then
    check "AppStream metadata validates" appstreamcli validate --no-net "$P/usr/share/metainfo/org.biglinux.big-storage-rescue.metainfo.xml"
fi
check "  ... its id is the one of the launcher and of the window" bash -c 'grep -q "<id>org.biglinux.big-storage-rescue</id>" "$1" && grep -q "^StartupWMClass=org.biglinux.big-storage-rescue$" "$2" && grep -q "APP_ID = \"org.biglinux.big-storage-rescue\"" "$3"' _ \
    "$P/usr/share/metainfo/org.biglinux.big-storage-rescue.metainfo.xml" "$P/usr/share/applications/org.biglinux.big-storage-rescue.desktop" "$P/usr/lib/big-storage-rescue/gui/application.py"
for f in usr/bin/big-storage-rescue usr/lib/big-storage-rescue/*.sh usr/lib/big-storage-rescue/bsr-holders usr/lib/big-storage-rescue/bsr-drive-helper usr/lib/big-storage-rescue/bsr-image-helper; do
    for g in "$P"/$f; do check "syntax: ${g#"$P"/}" bash -n "$g"; done
done

echo ""
echo "========================================="
echo "package result: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
