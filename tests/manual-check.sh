#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # helpers called through traps
# Guided manual validation of what automated tests cannot see: the real
# dialogs and notifications on the Plasma screen, the Dolphin menu, and a
# real boot. Disposable images are used as devices; no real disk is touched.
#
# Usage:
#   tests/manual-check.sh               dialogs, notifications, Dolphin menu
#   tests/manual-check.sh --after-boot  checks to run after rebooting with the package installed
#
# Answers are saved to big-storage-rescue-manual-check.txt in the current folder.

set -u
BM="${BM:-/usr/bin/big-storage-rescue}"
OUT="$PWD/big-storage-rescue-manual-check.txt"

ask() { # QUESTION -> records y/n
    local ans
    printf '\n\033[1m%s\033[0m [y/n] ' "$1"
    read -r ans
    case "$ans" in [yYsS]*) ans=yes ;; *) ans=NO ;; esac
    printf '%-4s %s\n' "$ans" "$1" >> "$OUT"
}
say() { printf '\n\033[36m== %s\033[0m\n%s\n' "$1" "$2"; }

# Mounting at boot belongs to Big-Mount, whose own manual check covers it.
# This package has no boot unit: only its notifier, when turned on, starts
# with the session
after_boot() {
    : > "$OUT"
    local units ok=yes
    units="$(systemctl list-unit-files --no-legend 'big-storage-rescue*' 2>/dev/null)"
    [ -z "$units" ] || ok=NO
    say "Boot units of this package (must be none)" "${units:-none}"
    printf '%-4s %s\n' "$ok" "big-storage-rescue has no boot unit" >> "$OUT"
    say "Notifier" "$(pgrep -a -f 'big-storage-rescue --notifier' || echo 'not running: it is off unless turned on in the menu')"
    ask "If you turned the notifier on: is it running, and did a drive with problems give ONE notification after login?"
    echo; echo "Answers saved to $OUT"
}

[ "${1:-}" = --after-boot ] && { after_boot; exit 0; }
[ "$EUID" -ne 0 ] || { echo "run it as your user, not as root" >&2; exit 2; }
[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] || { echo "run it inside the desktop session" >&2; exit 2; }

W="$(mktemp -d)"; LOOPS=() PIDS=()
cleanup() {
    local p d
    for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    for d in "${LOOPS[@]}"; do
        udisksctl unmount --no-user-interaction -b "$d" >/dev/null 2>&1
        udisksctl loop-delete --no-user-interaction -b "$d" >/dev/null 2>&1
    done
    rm -rf -- "${W:?}"
}
trap cleanup EXIT

device() { # LABEL [ro] -> DEV, MP
    truncate -s 64M "$W/$1.img"
    mkfs.ext4 -q -F -L "$1" -E root_owner="$(id -u):$(id -g)" "$W/$1.img"
    DEV="$(udisksctl loop-setup --no-user-interaction ${2:+-r} -f "$W/$1.img" | grep -o '/dev/loop[0-9]*')"
    LOOPS+=("$DEV"); udevadm settle
    udisksctl mount --no-user-interaction -b "$DEV" >/dev/null
    MP="$(findmnt -n -o TARGET --source "$DEV")"
}

: > "$OUT"
echo "Big Storage Rescue manual check: $("$BM" --help >/dev/null && echo "$BM") ($(pacman -Q big-storage-rescue 2>/dev/null))"
echo "Theme, scale and language are the ones of your session: run it again after changing them"
echo "(System Settings > Colors, Display > Scale 125/150/200 %) to check each case."

say "1. Read-only device: notification" "A write-protected test device will be mounted. Watch the notifications."
XDG_STATE_HOME="$W/state" "$BM" --notifier & PIDS+=("$!"); sleep 2
device BMWriteProtected ro
sleep 3
ask "Did ONE notification 'Read-only device' appear, with the Big Storage Rescue icon and the buttons 'View details' and 'How to solve'?"
ask "Did it disappear by itself after about 15 seconds (and stay in the notification history)?"

say "2. Diagnosis dialog" "The diagnosis of that device opens now. Look at it, then close it."
"$BM" --gui-diagnose "$DEV"
ask "Was the dialog readable (theme, dark/light, scale, no text cut off) and did it explain the lock switch?"

say "3. Busy device and safe removal" "A program will hold a folder of a test device. In the dialog: 'More options…' > 'Close the listed programs…'. Pressing Enter in the confirmation must NOT close anything; then click 'Close them'."
device BMBusyDevice
( cd "$MP" && exec sleep 600 ) & PIDS+=("$!")
sleep 1
"$BM" --gui-remove "$MP"
sleep 2
ask "Did the dialog start with a plain sentence about the program and what to do?"
ask "Was Cancel the default button of 'Close these programs?' (Enter did nothing)?"
ask "After closing it, did a 5-second notification say the device was unmounted?"

say "4. Dolphin menu" "Dolphin opens on a test device. Right-click inside the folder: Storage device > Why can't I write here? / Safely remove."
device BMDolphinMenu
dolphin --new-window "$MP" >/dev/null 2>&1 &
ask "Did the 'Storage device' submenu appear with both actions, and did they open the Big Storage Rescue dialogs?"

say "5. Screen reader (optional)" "With Orca running (Meta+Alt+S), open: $BM --gui-diagnose $DEV"
ask "Did Orca read the dialog text and the buttons?"

echo; echo "Answers saved to $OUT:"; cat "$OUT"
