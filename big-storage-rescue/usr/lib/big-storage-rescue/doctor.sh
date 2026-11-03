# shellcheck shell=bash
#
# Big Storage Rescue self-check: big-storage-rescue --version and --doctor.
#
# Answers "which Big Storage Rescue is installed, which code is it running, and is
# the storage stack around it healthy?" without administrator rights and
# without changing anything: no mount, no unmount, no file written outside
# the terminal. Loaded by cli.sh only for these two commands.
#
# The report is meant to be pasted into a bug report, so it never prints
# volume labels, serial numbers, UUIDs, the user name, the home folder or
# the folders where devices are mounted (they usually carry the label).

BSR_VERSION=1.0.0

# ---------------------------------------------------------------------------
# --version

# bsr_version_info: V_REVISION, V_DATE, V_SOURCE (where the code came from)
# and V_PKG (the installed package, when this is the packaged copy).
# The PKGBUILD writes $BSR_LIB_DIR/version as KEY=value lines; it is read as
# data and every value is checked, never sourced.
bsr_version_info() {
   local f="$BSR_LIB_DIR/version" key val top
   V_REVISION="" V_DATE="" V_SOURCE="" V_PKG=""
   if [ -r "$f" ]; then
      while IFS='=' read -r key val; do
         case "$key" in
            revision) [[ $val =~ ^[0-9a-f]{7,40}(-dirty)?$ ]] && V_REVISION="$val" ;;
            date) [[ $val =~ ^[0-9T:+-]+Z?$ ]] && V_DATE="$val" ;;
            source) [[ $val =~ ^https://[A-Za-z0-9./_-]+$ ]] && V_SOURCE="$val" ;;
         esac
      done < "$f"
   else
      # A source checkout: ask git, when there is one
      if command -v git >/dev/null && top="$(git -C "$BSR_LIB_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
         V_REVISION="$(git -C "$top" describe --always --dirty --tags 2>/dev/null)"
         V_DATE="$(TZ=UTC git -C "$top" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd 2>/dev/null)"
      fi
      V_SOURCE=$"source checkout (not installed by a package)"
   fi
   if [ "$BSR_LIB_DIR" = /usr/lib/big-storage-rescue ] && command -v pacman >/dev/null; then
      V_PKG="$(pacman -Qqo /usr/bin/big-storage-rescue 2>/dev/null | head -n1)"
      [ -n "$V_PKG" ] && V_PKG="$(pacman -Q -- "$V_PKG" 2>/dev/null)"
   fi
}

bsr_cmd_version() {
   local l_pkg=$"package:" l_rev=$"revision:" l_src=$"source:" w
   bsr_version_info
   # Labels are aligned by characters (translations have accents)
   w="${#l_pkg}"
   [ "${#l_rev}" -gt "$w" ] && w="${#l_rev}"
   [ "${#l_src}" -gt "$w" ] && w="${#l_src}"
   printf 'Big Storage Rescue %s\n' "$BSR_VERSION"
   [ -n "$V_PKG" ] && { bsr_pad "$l_pkg" "$w"; printf '  %s %s\n' "$REPLY" "$V_PKG"; }
   [ -n "$V_REVISION" ] || V_REVISION=$"unknown"
   bsr_pad "$l_rev" "$w"; printf '  %s %s\n' "$REPLY" "$V_REVISION${V_DATE:+ ($V_DATE)}"
   [ -n "$V_SOURCE" ] && { bsr_pad "$l_src" "$w"; printf '  %s %s\n' "$REPLY" "$V_SOURCE"; }
   return 0
}

# ---------------------------------------------------------------------------
# --doctor

# Private data never reaches the report: the home folder becomes ~ and the
# folders of the user under /run/media and /media become <user>. The bare
# user name is left alone: it could be part of anything (a URL, a model).
bsr_dr_anon() {
   local s="$1"
   [ -n "${HOME:-}" ] && [ "$HOME" != / ] && s="${s//"$HOME"/"~"}"
   if [ -n "${DR_USER:-}" ]; then
      s="${s//"/run/media/$DR_USER"/"/run/media/<user>"}"
      s="${s//"/media/$DR_USER"/"/media/<user>"}"
   fi
   # Control characters from device data, except line breaks
   REPLY="${s//[$'\001'-$'\011'$'\013'-$'\037'$'\177']/?}"
}

# bsr_dr LEVEL TEXT [DETAIL]: one line of the report.
# LEVEL: ok | info | warn | fail
bsr_dr() {
   local level="$1" text="$2" detail="${3:-}" tag
   case "$level" in
      ok) tag=" OK " ;;
      info) tag="INFO" ;;
      warn) tag="WARN"; DR_WARN=$((DR_WARN + 1)) ;;
      fail) tag="FAIL"; DR_FAIL=$((DR_FAIL + 1)) ;;
   esac
   if [ -n "$DR_COLOR" ]; then
      case "$level" in
         ok) tag=$'\e[32m'"$tag"$'\e[0m' ;;
         warn) tag=$'\e[33m'"$tag"$'\e[0m' ;;
         fail) tag=$'\e[1;31m'"$tag"$'\e[0m' ;;
      esac
   fi
   bsr_dr_anon "$text"; text="$REPLY"
   printf '  [%s] %s\n' "$tag" "$text"
   if [ -n "$detail" ]; then
      bsr_dr_anon "$detail"
      printf '         %s\n' "${REPLY//$'\n'/$'\n'         }"
   fi
}

bsr_dr_section() { printf '\n%s\n' "$1"; }

# Messages with data: a translated FORMAT and its ARGS, into REPLY
# shellcheck disable=SC2059
bsr_fmt() { local f="$1"; shift; printf -v REPLY -- "$f" "$@"; }

# Version of a program, first line only, or nothing
bsr_dr_ver() {
   REPLY=""
   command -v "$1" >/dev/null || return 1
   REPLY="$(timeout 5 "$@" 2>&1 | head -n1)"
   REPLY="${REPLY//[[:cntrl:]]/}"
}

bsr_dr_install() {
   local f p found=() n=0 st mode own altered
   bsr_dr_section $"Big Storage Rescue"
   bsr_version_info
   bsr_dr info "Big Storage Rescue $BSR_VERSION, ${V_REVISION:-?}${V_DATE:+ ($V_DATE)}" "$V_PKG"
   if [ "$BSR_LIB_DIR" != /usr/lib/big-storage-rescue ]; then
      bsr_dr info $"This is not the installed copy (a source checkout or an unpacked package); the installed one is checked below."
   fi

   # Every big-storage-rescue in PATH: a copy in /usr/local/bin or ~/bin hides
   # the package and is a classic reason for "it works on the other computer"
   mapfile -t found < <(type -ap big-storage-rescue 2>/dev/null)
   if [ "${#found[@]}" -eq 0 ]; then
      bsr_dr fail $"big-storage-rescue is not in PATH" $"Install the big-storage-rescue package."
   else
      for p in "${found[@]}"; do
         [ "$(readlink -f -- "$p")" = /usr/bin/big-storage-rescue ] || n=$((n + 1))
      done
      if [ "$n" -gt 0 ]; then
         bsr_dr warn $"Another copy of big-storage-rescue is found in PATH before or besides the package" "${found[*]}"
      fi
   fi

   if [ -e /usr/bin/big-storage-rescue ]; then
      for f in cli.sh lib.sh ui.sh doctor.sh migrate.sh system-check.sh drive.sh drive-detect.sh drive-diag.sh drive-copy.sh \
         drive-recovery.sh drive-salvage.sh drive-tui.sh app.py dialog.py integrity.py bsr-holders bsr-drive-helper bsr-image-helper; do
         f="/usr/lib/big-storage-rescue/$f"
         [ -e "$f" ] && continue
         bsr_fmt $"Missing file of the package: %s" "$f"
         bsr_dr fail "$REPLY" $"Reinstall the big-storage-rescue package."
      done
      for f in /usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy \
         /usr/share/applications/org.biglinux.big-storage-rescue.desktop \
         /usr/share/kio/servicemenus/big-storage-rescue.desktop; do
         [ -e "$f" ] && continue
         bsr_fmt $"Missing file of the package: %s" "$f"
         bsr_dr fail "$REPLY" $"Reinstall the big-storage-rescue package."
      done
   else
      bsr_dr fail $"/usr/bin/big-storage-rescue is missing" $"Install the big-storage-rescue package."
   fi

   # Code that runs as root (the pkexec helpers) must not be writable by
   # anyone else
   for f in /usr/bin/big-storage-rescue /usr/lib/big-storage-rescue /usr/lib/big-storage-rescue/*; do
      [ -e "$f" ] || continue
      st="$(stat -c '%U %a' -- "$f" 2>/dev/null)" || continue
      own="${st% *}" mode="${st#* }"
      if [ "$own" != root ] || (( 8#$mode & 8#022 )); then
         bsr_fmt $"Unsafe owner or permissions: %s (%s)" "$f" "$st"
         bsr_dr fail "$REPLY" $"Reinstall the big-storage-rescue package."
      fi
   done

   if command -v pacman >/dev/null && pacman -Q big-storage-rescue >/dev/null 2>&1; then
      altered="$(LC_ALL=C pacman -Qkk big-storage-rescue 2>&1 | grep -vE '^big-storage-rescue: [0-9]+ total files' | grep -E 'warning|error' | sed 's/^warning: //;s/^error: //')"
      # BigLinux adds the graphics card options to every menu entry
      # (render-menu-options watches /usr/share/applications): expected
      if grep -q ' /usr/share/applications/[^ ]*\.desktop ' <<< "$altered"; then
         altered="$(grep -v ' /usr/share/applications/[^ ]*\.desktop ' <<< "$altered")"
         bsr_dr info $"The menu entry was changed after installation, as BigLinux does to add the graphics card options"
      fi
      if [ -n "$altered" ]; then
         bsr_dr warn $"Installed files differ from the package" "$altered"
      else
         bsr_dr ok $"Installed files match the package"
      fi
      local url repo
      url="$(LC_ALL=C pacman -Qi big-storage-rescue 2>/dev/null | sed -n 's/^URL *: //p')"
      [ -n "$url" ] && { bsr_fmt $"Package built from %s" "$url"; bsr_dr info "$REPLY"; }
      repo="$(LC_ALL=C pacman -Si big-storage-rescue 2>/dev/null | sed -n 's/^Repository *: //p;s/^Version *: //p' | paste -sd' ')"
      if [ -n "$repo" ]; then
         local inst="${V_PKG#* }" rv="${repo#* }"
         command -v vercmp >/dev/null || inst=""
         [ -n "$inst" ] && case "$(vercmp "$inst" "$rv" 2>/dev/null)" in
            -1)
               bsr_fmt $"A newer version is in the repository (%s: %s); installed: %s" "${repo% *}" "$rv" "$inst"
               bsr_dr warn "$REPLY" $"Update the whole system: sudo pacman -Syu"
               ;;
            1)
               bsr_fmt $"The installed version (%s) is newer than the one of the repository (%s: %s)" "$inst" "${repo% *}" "$rv"
               bsr_dr info "$REPLY"
               ;;
         esac
      fi
   fi

   # What was brought over from Big-Mount 2.x (migrate.sh)
   local state="${XDG_STATE_HOME:-$HOME/.local/state}"
   if [ -e "$state/big-storage-rescue/migrated-from-big-mount" ]; then
      bsr_fmt $"Copies and settings of Big-Mount 2.x were brought over: %s job(s); the originals are kept in ~/.local/state/big-mount" \
         "$(grep '^moved ' "$state/big-storage-rescue/migration.log" 2>/dev/null | sort -u | wc -l)"
      bsr_dr info "$REPLY"
   elif [ -d "$state/big-mount/jobs" ]; then
      bsr_dr info $"Copies of Big-Mount 2.x were not brought over yet" $"They are when the application or big-storage-rescue --cli starts, or with: big-storage-rescue --migrate-state"
   fi
}

# Big-Mount mounts the internal partitions at boot. It is a separate package:
# this program works without it, and only reads what it left behind.
bsr_dr_bigmount() {
   local enabled active result s line n=0 failed=() warns=()
   bsr_dr_section $"Mounting at boot (Big-Mount, optional)"
   enabled="$(systemctl is-enabled big-mount.service 2>/dev/null)"
   if [ -z "$enabled" ] && [ ! -e /usr/bin/bigmount ]; then
      bsr_dr info $"Big-Mount is not installed: internal partitions are mounted by /etc/fstab, by the desktop or by hand"
      return 0
   fi
   # A Big-Mount from before the split still carries its own rescue tools:
   # then there are two applications in the menu until it is updated
   if [ -e /usr/lib/big-mount/drive-gui.py ] || [ -e /usr/lib/big-mount/drive-copy.sh ]; then
      bsr_dr warn $"The installed Big-Mount is from before Big Storage Rescue and still has its own drive manager" $"Update the whole system (sudo pacman -Syu): the new Big-Mount only mounts at boot."
   fi
   [ -e /etc/bigmountall-no ] && bsr_dr info $"/etc/bigmountall-no exists: mounting at boot is disabled on purpose"
   active="$(systemctl is-active big-mount.service 2>/dev/null)"
   result="$(systemctl show -p Result --value big-mount.service 2>/dev/null)"
   case "$enabled" in
      enabled) bsr_dr ok $"big-mount.service is enabled at boot" ;;
      *) bsr_fmt $"big-mount.service is not enabled at boot (%s)" "${enabled:-?}"; bsr_dr info "$REPLY" ;;
   esac
   if [ "$enabled" = enabled ] && { [ "$active" != active ] || [ "${result:-success}" != success ]; }; then
      bsr_fmt $"big-mount.service in this boot: %s (%s)" "${active:-?}" "${result:-?}"
      bsr_dr warn "$REPLY" $"See: journalctl -b -u big-mount"
   fi

   # What the boot run did, without mount points (they carry the labels)
   if [ -r "$BSR_STATUS_FILE" ]; then
      while IFS=$'\t' read -r dev _ _ s line; do
         [[ $dev == /dev/* ]] || continue
         n=$((n + 1))
         [ "$s" = failed ] && failed+=("$dev: $line")
         [ "$s" = ro ] && warns+=("$dev: $line")
      done < "$BSR_STATUS_FILE"
      bsr_fmt $"Partitions handled by Big-Mount at boot: %d" "$n"; bsr_dr info "$REPLY"
      [ "${#failed[@]}" -gt 0 ] && bsr_dr warn $"Failed at boot" "$(printf '%s\n' "${failed[@]}")"$'\n'$"To know why: big-storage-rescue --diagnose DEVICE"
      [ "${#warns[@]}" -gt 0 ] && bsr_dr warn $"Mounted read-only at boot" "$(printf '%s\n' "${warns[@]}")"$'\n'$"To know why: big-storage-rescue --diagnose DEVICE"
   fi
}

bsr_dr_session() {
   local s rundir="${XDG_RUNTIME_DIR:-/run/user/$EUID}"
   bsr_dr_section $"Desktop session"
   bsr_fmt $"Session: %s, desktop: %s, language: %s" "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}" "${LC_ALL:-${LC_MESSAGES:-${LANG:-?}}}"
   bsr_dr info "$REPLY"
   # Drive manager: only what it offers depends on these
   local dt=0 dt_tools=(rsync smartctl ddrescue testdisk photorec)
   local dt_uses=($"copying files off a drive" $"SMART details" $"disk images" $"lost partitions" $"search by content")
   for dt in "${!dt_tools[@]}"; do
      if command -v "${dt_tools[dt]}" >/dev/null; then bsr_fmt $"Drive manager, %s: %s" "${dt_uses[dt]}" "${dt_tools[dt]}"; bsr_dr ok "$REPLY"
      else bsr_fmt $"Drive manager, %s: %s is not installed" "${dt_uses[dt]}" "${dt_tools[dt]}"; bsr_dr info "$REPLY"
      fi
   done
   if command -v python3 >/dev/null && python3 -I -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1"); from gi.repository import Adw; raise SystemExit((Adw.MAJOR_VERSION, Adw.MINOR_VERSION) < (1, 5))' 2>/dev/null; then bsr_dr ok $"Application and dialogs: GTK 4 and libadwaita"
   else bsr_dr warn $"The application and the dialogs need gtk4, libadwaita 1.5 or later and python-gobject: big-storage-rescue --gui cannot open and questions are asked in the terminal. big-storage-rescue --cli works without them"
   fi
   if command -v notify-send >/dev/null; then bsr_dr ok $"Notifications: notify-send"
   else bsr_dr warn $"notify-send (libnotify) is not installed: no notifications" $"Install libnotify."
   fi
   if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
      [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || bsr_dr warn $"No session D-Bus: notifications cannot be shown"
      local running=0
      [ -e "$rundir/big-storage-rescue-notifier.lock" ] && ! flock -n "$rundir/big-storage-rescue-notifier.lock" true 2>/dev/null && running=1
      local entry="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/big-storage-rescue-notifier.desktop"
      if [ ! -e "$entry" ] || grep -qx -e 'Hidden=true' -e 'X-GNOME-Autostart-enabled=false' "$entry"; then
         bsr_dr info $"The read-only notifier is off (it can be turned on in the menu of the application)"
      elif [ "$running" = 1 ]; then
         bsr_dr ok $"The read-only notifier is running"
      else
         bsr_dr warn $"The read-only notifier is on but not running" $"It starts at the next login."
      fi
   fi
   if command -v pacman >/dev/null; then
      s="$(pacman -Q plasma-workspace dolphin 2>/dev/null | paste -sd, | sed 's/,/, /g')"
      [ -n "$s" ] && bsr_dr info "$s"
   fi
}

bsr_dr_storage() {
   local line s name tran rm hp type n v ud_devs=() ns
   bsr_dr_section $"Storage stack"
   bsr_dr_ver uname -r; v="kernel $REPLY"
   v+=", bash ${BASH_VERSION%%(*}"
   bsr_dr_ver lsblk --version; v+=", util-linux ${REPLY##* }"
   s="$(busctl get-property org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager Version 2>/dev/null)"
   s="${s#s \"}"; v+=", udisks ${s%\"}"
   bsr_dr_ver systemctl --version; v+=", ${REPLY%% (*}"
   bsr_dr info "$v"

   for s in lsblk findmnt blkid udevadm udisksctl lsof flock setpriv gdbus; do
      command -v "$s" >/dev/null && continue
      bsr_fmt $"Missing program: %s" "$s"
      bsr_dr fail "$REPLY" $"Install the dependencies of big-storage-rescue (util-linux, udisks2, lsof, glib2)."
   done
   if busctl --system --no-pager status org.freedesktop.UDisks2 >/dev/null 2>&1; then
      bsr_dr ok $"UDisks2 answers on the system D-Bus"
   else
      bsr_dr fail $"UDisks2 does not answer on the system D-Bus" $"Plasma and Big Storage Rescue cannot mount or remove devices. Check: systemctl status udisks2"
   fi
   if command -v pkaction >/dev/null; then
      if pkaction --action-id org.biglinux.big-storage-rescue.inspect-processes >/dev/null 2>&1; then
         bsr_dr ok $"Polkit knows the action of Big Storage Rescue"
      else
         bsr_dr warn $"Polkit does not know org.biglinux.big-storage-rescue.inspect-processes" $"'Show programs of all users' will not work. Reinstall the big-storage-rescue package."
      fi
   fi
   if journalctl -k -b -q -n 1 >/dev/null 2>&1 && [ -n "$(journalctl -k -b -q -n 1 2>/dev/null)" ]; then
      bsr_dr ok $"Kernel log readable (needed to explain read-only devices)"
   else
      bsr_dr info $"Kernel log not readable by this user: read-only causes are explained with fewer details"
   fi

   # Every disk the kernel shows must be known to UDisks2 under the same
   # name: that is the lookup that failed with "/dev/nvme" in old versions
   mapfile -t ud_devs < <(LC_ALL=C udisksctl dump 2>/dev/null | sed -n 's/^ *Device: *\(\/dev\/[^ ]*\)$/\1/p')
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      name="${KV[NAME]}" tran="${KV[TRAN]:-}" rm="${KV[RM]}" hp="${KV[HOTPLUG]}" type="${KV[TYPE]}"
      case "${name##*/}" in zram* | ram* | loop*) continue ;; esac
      [ "$type" = disk ] || continue
      bsr_human_size "${KV[SIZE]}"
      if [ "$rm" = 1 ] || [ "$hp" = 1 ] || [ "$tran" = usb ]; then
         bsr_fmt $"%s: %s, %s, removable" "${name##*/}" "${tran:-?}" "$REPLY"
      else
         bsr_fmt $"%s: %s, %s, internal" "${name##*/}" "${tran:-?}" "$REPLY"
      fi
      s="$REPLY"
      if [ ! -e "/sys/block/${name##*/}" ]; then
         bsr_dr fail "$s" $"The kernel has no /sys/block entry for it"
      elif [ "${#ud_devs[@]}" -gt 0 ] && [[ " ${ud_devs[*]} " != *" $name "* ]]; then
         bsr_dr warn "$s" $"UDisks2 does not know this device: Plasma and Big Storage Rescue cannot manage it"
      else
         bsr_dr ok "$s"
      fi
      # SMART failure, timeouts and I/O errors of this boot (read-only, as the user)
      bsr_drive_health "$name" </dev/null
      if [ "${#DH_FIND[@]}" -gt 0 ]; then
         bsr_fmt $"%s: the drive reports problems (%s)" "${name##*/}" "${DH_FIND[*]}"; s="$REPLY"
         bsr_fmt $"For details: big-storage-rescue --diagnose %s" "$name"
         bsr_dr warn "$s" "$REPLY"
      fi
      # Earlier starts (internal drives) and the counters of its filesystems
      bsr_drive_past "$name" </dev/null
      if [ "$DHI_PAST" = 1 ]; then
         bsr_fmt $"%s: errors in %s of the last %s starts of the computer (%s kernel messages)" "${name##*/}" "$DHI_BAD" "$DHI_BOOTS" "$DHI_COUNT"; s="$REPLY"
         bsr_fmt $"For details: big-storage-rescue --diagnose %s" "$name"
         bsr_dr warn "$s" "$REPLY"
      fi
      if [ "$FSE_TOTAL" -gt 0 ]; then
         bsr_fmt $"%s: its filesystems recorded %s errors, kept across restarts" "${name##*/}" "$FSE_TOTAL"
         bsr_dr warn "$REPLY" "$(printf '%s\n' "${FSE_LIST[@]}")"
      fi
   done < <(lsblk -P -b -p -d -o NAME,TYPE,TRAN,RM,HOTPLUG,SIZE 2>/dev/null)

   # NVMe: a controller (/dev/nvme0) holds namespaces (/dev/nvme0n1), which
   # hold partitions (/dev/nvme0n1p1). Only namespaces and partitions store data.
   for n in /sys/class/nvme/nvme*; do
      [ -e "$n" ] || continue
      ns=()
      for s in "$n"/nvme*n*; do [ -b "/dev/${s##*/}" ] && ns+=("/dev/${s##*/}"); done
      bsr_fmt $"NVMe controller /dev/%s: storage %s" "${n##*/}" "${ns[*]:-?}"; bsr_dr info "$REPLY"
   done

   # Filesystems mounted read-only that are not read-only by nature
   local ro=()
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      [[ ${KV[SOURCE]} == /dev/* ]] || continue
      case "${KV[FSTYPE]}" in squashfs | iso9660 | udf | erofs) continue ;; esac
      bsr_has_opt "${KV[OPTIONS]}" ro || continue
      [[ " ${ro[*]} " == *" ${KV[SOURCE]%%\[*} "* ]] || ro+=("${KV[SOURCE]%%\[*}")
   done < <(findmnt -P -n -o SOURCE,FSTYPE,OPTIONS 2>/dev/null)
   if [ "${#ro[@]}" -gt 0 ]; then
      bsr_fmt $"Mounted read-only: %s" "${ro[*]}"; bsr_dr warn "$REPLY" $"To know why: big-storage-rescue --diagnose DEVICE"
   fi
}

# The storage of the running system (system-check.sh): free space, room of
# Btrfs, partitions left mounted by os-prober
bsr_dr_system() {
   local i
   bsr_dr_section $"Running system"
   bsr_load system-check.sh
   bsr_sc_run
   if [ "${#SC_KEY[@]}" -eq 0 ]; then
      bsr_dr ok $"Enough free space, and nothing left mounted by os-prober"
      return 0
   fi
   for i in "${!SC_KEY[@]}"; do
      case "${SC_LEVEL[i]}" in
         critical) bsr_dr fail "${SC_TEXT[i]}" "${SC_HELP[i]}" ;;
         *) bsr_dr warn "${SC_TEXT[i]}" "${SC_HELP[i]}" ;;
      esac
   done
}

# Symptoms reported together with storage problems that belong to the
# desktop, not to Big Storage Rescue. Only facts that can be read without risk.
bsr_dr_outside() {
   local cfg="${XDG_CONFIG_HOME:-$HOME/.config}" foreign=() f n
   bsr_dr_section $"Outside Big Storage Rescue (for reference)"
   if [ -d "$cfg" ]; then
      # Full paths: the report turns the home folder into ~
      while IFS= read -r -d '' f; do foreign+=("$f"); done \
         < <(find "$cfg" -maxdepth 2 ! -user "$EUID" -print0 2>/dev/null | head -z -n 20)
      if [ "${#foreign[@]}" -gt 0 ]; then
         bsr_dr warn $"Settings files that do not belong to you (Plasma cannot save them, so settings seem to reset)" \
            "$(printf '%s\n' "${foreign[@]}")"$'\n'$"Usually left by a graphical program run with sudo. An administrator can give them back with chown."
      else
         bsr_dr ok $"All your settings files belong to you"
      fi
   fi
   if command -v pacman >/dev/null; then
      n="$(pacman -Qu 2>/dev/null | wc -l)"
      if [ "$n" -gt 0 ]; then
         bsr_fmt $"%d packages have newer versions in the last synchronized package list" "$n"
         bsr_dr info "$REPLY" $"Keep the system consistent: update everything at once (sudo pacman -Syu), never only some packages."
      fi
   fi
}

bsr_cmd_doctor() {
   if [ "$#" -gt 0 ]; then
      printf $"big-storage-rescue: unknown option '%s' (see big-storage-rescue --help)"'\n' "$1" >&2
      return 2
   fi
   DR_WARN=0 DR_FAIL=0 DR_COLOR=""
   DR_USER="$(id -un 2>/dev/null)"
   [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && DR_COLOR=1
   printf '%s\n' $"Big Storage Rescue check (nothing is changed; labels, serial numbers, UUIDs and personal paths are left out)"
   bsr_dr_install
   bsr_dr_bigmount
   bsr_dr_session
   bsr_dr_storage
   bsr_dr_system
   bsr_dr_outside
   printf '\n'
   printf $"Result: %d problem(s), %d warning(s)."'\n' "$DR_FAIL" "$DR_WARN"
   [ "$DR_FAIL" -eq 0 ] && [ "$DR_WARN" -eq 0 ] && printf '%s\n' $"Big Storage Rescue and the storage stack look healthy."
   printf '%s\n' $"To report a problem, attach this output: big-storage-rescue --doctor > big-storage-rescue-report.txt"
   [ "$DR_FAIL" -eq 0 ]
}
