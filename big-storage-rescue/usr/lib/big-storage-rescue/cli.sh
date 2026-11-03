# shellcheck shell=bash
#
# Big Storage Rescue: the command line. Storage diagnosis, "what is using this
# device", safe removal, the health of drives, the session notifier, and the
# way into the drive manager (--cli) and the application (--gui).
#
# Exit codes: 0 done, 1 error, 2 usage, 3 device busy, 4 refused (holds the
# running system), 5 not authorized or cancelled, 6 unmounted but still in
# use by a stacked device, 7 unmounted, the drive cannot be powered off by
# the computer, 8 unmounted but powering it off failed, 9 not done: services
# depend on the device and the user did not confirm stopping them, 10 not
# done: another operation on the same drive is in progress.
# The drive manager adds 20 to 25 (drive.sh).

BSR_LIB_DIR="${BSR_LIB:-/usr/lib/big-storage-rescue}"
# shellcheck source=lib.sh
. "$BSR_LIB_DIR/lib.sh"
# shellcheck source=ui.sh
. "$BSR_LIB_DIR/ui.sh"

bsr_usage() {
   printf $"Usage: big-storage-rescue [OPTION] [DEVICE|FOLDER]"'\n\n'
   # shellcheck disable=SC2247  # $"(none)" is a translatable string
   printf '  %-28s %s\n' \
      $"(none)" $"the application in a graphical session, the manager in a terminal" \
      "--gui [TARGET]" $"the application: drives, health and file rescue" \
      "--gui-health [TARGET]" $"the same application, opened on the health of the drive" \
      "--gui-rescue [TARGET]" $"the same application, opened on the recovery of files from it" \
      "--cli [COMMAND]" $"drive manager and file rescue in the terminal (big-storage-rescue --cli --help)" \
      "--diagnose [TARGET]" $"storage overview, or details of one device (a whole disk: drive errors)" \
      "--busy TARGET" $"show what keeps a device busy" \
      "--unmount TARGET" $"unmount one filesystem safely" \
      "--safe-remove TARGET" $"unmount every filesystem of the drive and power it off" \
      "  --no-power-off" $"with --safe-remove: unmount everything, do not power it off" \
      "  --close-apps" $"offer to close the programs that keep it busy" \
      "  --assume-yes" $"do not ask before closing them or stopping services (scripts)" \
      "--gui-diagnose [TARGET]" $"graphical diagnosis of one device (Dolphin menu)" \
      "--gui-remove TARGET" $"graphical safe removal (Dolphin menu)" \
      "--notifier" $"session service: warn about read-only devices" \
      "--migrate-state" $"bring the copies and settings of Big-Mount 2.x over (also done on start)" \
      "--doctor" $"check the installation and the storage stack (for bug reports)" \
      "-V, --version" $"show the version and the source revision" \
      "-h, --help" $"show this help"
   printf '\n%s\n' $"TARGET is a device (/dev/sdb1) or any folder inside a mounted device."
   printf '%s\n' $"Machine-readable output: big-storage-rescue --cli COMMAND --json"
}

# Parts that only one command needs are loaded by that command
bsr_load() {
   # shellcheck source=doctor.sh
   . "$BSR_LIB_DIR/$1"
}

# A graphical session this user can open a window in
bsr_has_display() {
   [ "$EUID" -ne 0 ] && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]
}

bsr_main() {
   local cmd="${1:-}" a args=()
   [ "$#" -gt 0 ] && shift
   if [ -z "$cmd" ]; then
      if bsr_has_display; then cmd=--gui
      elif [ -t 0 ] && [ -t 1 ]; then cmd=--cli
      else bsr_usage; return 2
      fi
   fi
   # The drive manager has subcommands and resolves paths on its own.
   # --drive is the name it had in Big-Mount (bigmount --drive)
   if [ "$cmd" = --cli ] || [ "$cmd" = --drive ]; then
      # shellcheck disable=SC2034  # read by drive.sh
      BSR_CWD="$PWD"
      cd / || return 1
      bsr_migrate_quietly "$@"
      bsr_load drive.sh && bsr_drive_main "$@"
      return
   fi
   # The application takes a device, a folder or a UUID, which is not a path
   case "$cmd" in
      --gui | --gui-health | --gui-rescue)
         if [ "$#" -gt 0 ] && [ -z "$1" ]; then
            R_ERR=empty; bsr_resolve_fail ""
            return 2
         fi
         # shellcheck disable=SC2034  # read by drive.sh
         BSR_CWD="$PWD"
         cd / || return 1
         bsr_migrate_quietly
         bsr_load drive.sh || return 1
         case "$cmd" in
            --gui-health) bsr_gui_drive_main health "$@" ;;
            --gui-rescue) bsr_gui_drive_main rescue "$@" ;;
            *) bsr_gui_drive_main "" "$@" ;;
         esac
         return
         ;;
   esac
   # Relative paths are resolved now: we leave the current folder below
   for a in "$@"; do
      # An empty target must not silently become the current folder
      if [ -z "$a" ]; then
         R_ERR=empty; bsr_resolve_fail ""
         return 2
      fi
      if [[ $a != -* && $a != /* ]]; then a="$PWD/$a"; fi
      args+=("$a")
   done
   # Dolphin may start us inside the very device we must release
   cd / || return 1
   case "$cmd" in
      -h | --help) bsr_usage ;;
      -V | --version) bsr_load doctor.sh && bsr_cmd_version ;;
      --doctor) bsr_load doctor.sh && bsr_cmd_doctor "${args[@]}" ;;
      --diagnose) BSR_UI="tty"; bsr_ui_init; bsr_cmd_diagnose "${args[@]}" ;;
      --busy) BSR_UI="tty"; bsr_ui_init; bsr_cmd_busy "${args[@]}" ;;
      --unmount) BSR_UI="tty"; bsr_ui_init; bsr_cmd_remove unmount "${args[@]}" ;;
      --safe-remove) BSR_UI="tty"; bsr_ui_init; bsr_cmd_remove remove "${args[@]}" ;;
      --gui-diagnose) bsr_ui_init; bsr_gui_diagnose "${args[@]}" ;;
      --gui-remove) bsr_ui_init; bsr_gui_remove "${args[@]}" ;;
      --notifier) bsr_ui_init; bsr_notifier ;;
      --migrate-state) bsr_load migrate.sh && bsr_migrate_cmd "${args[@]}" ;;
      *)
         printf $"big-storage-rescue: unknown option '%s' (see big-storage-rescue --help)"'\n' "$cmd" >&2
         return 2
         ;;
   esac
}

# The copies of Big-Mount 2.x come over the first time they are needed. Only a
# look at two folders when there is nothing to do; a question about the state
# of a job (status, jobs, the window) then finds them. Never for __run: a
# supervisor that is starting must not wait for anything, and never for a
# --dry-run, which changes nothing.
bsr_migrate_quietly() {
   local a
   [ "${1:-}" = __run ] && return 0
   [ -d "${XDG_STATE_HOME:-$HOME/.local/state}/big-mount" ] || [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/big-mount" ] || return 0
   [ -e "${XDG_STATE_HOME:-$HOME/.local/state}/big-storage-rescue/migrated-from-big-mount" ] && return 0
   for a in "$@"; do
      if [ "$a" = --dry-run ]; then
         printf '%s\n' $"The jobs of Big-Mount 2.x are not brought over by a dry run. To see them here, run first: big-storage-rescue --migrate-state" >&2
         return 0
      fi
   done
   bsr_load migrate.sh && bsr_migrate_run auto >/dev/null 2>&1
   return 0
}

# ---------------------------------------------------------------------------
# Texts for each diagnosis (translatable, no markup)

# bsr_cause_text CAUSE: C_TITLE, C_REASON, C_HELP (steps), C_FIX_LABEL, C_FIX_INFO
bsr_cause_text() {
   C_TITLE="" C_REASON="" C_HELP=() C_FIX_LABEL="" C_FIX_INFO=""
   case "$1" in
      ok)
         C_TITLE=$"Device ready"
         C_REASON=$"You can read and write files on this device."
         ;;
      not-mounted)
         C_TITLE=$"Device not mounted"
         C_REASON=$"The filesystem is not mounted at the moment."
         C_HELP=($"Open the device in the file manager (Dolphin) to mount it.")
         ;;
      hw-readonly)
         C_TITLE=$"Read-only device"
         C_REASON=$"The device itself is write-protected, so no system can write to it."
         C_HELP=($"SD cards and some USB drives have a small lock switch on the side. Remove the device, move the switch to the unlocked position and connect it again."
            $"If there is no switch, the device may have locked itself because of wear. Copy your files to another place as soon as possible.")
         ;;
      unsupported)
         C_TITLE=$"Read-only device"
         C_REASON=$"This kind of filesystem cannot be written on Linux with the driver in use."
         C_HELP=($"CDs, DVDs and disk images (ISO, SquashFS) are read-only by nature."
            $"Drives formatted on a Mac (HFS+ with journaling, APFS) can only be read on Linux."
            $"To write to it, copy the files elsewhere and format the device with a filesystem such as exFAT. Formatting erases everything on it.")
         ;;
      ntfs-unsafe)
         C_TITLE=$"Read-only device"
         C_REASON=$"Windows did not close this NTFS partition properly (hibernation, Fast Startup or an interrupted shutdown). Writing to it now could damage files."
         C_HELP=($"Start Windows and shut it down completely: hold the Shift key while you click Shut down."
            $"To avoid this in the future, disable Fast Startup in Windows: Control Panel > Power Options > Choose what the power buttons do."
            $"If it still happens, check the partition in Windows: open the Command Prompt as administrator and run chkdsk with the /f option for that drive letter."
            $"Big Storage Rescue never repairs NTFS by itself, because the repair tools available on Linux may discard data that Windows still needs.")
         ;;
      fs-errors)
         C_TITLE=$"The filesystem needs attention"
         C_REASON=$"The system found errors in the filesystem and stopped writing to it to protect your files."
         C_HELP=($"First copy your important files to another place."
            $"Then check the filesystem with the device unmounted, for example with KDE Partition Manager (Check)."
            $"Do not write to the device until it has been checked.")
         ;;
      io-errors)
         C_TITLE=$"The device has read or write errors"
         C_REASON=$"The device reported read or write errors. This is usually a bad cable, a weak USB port or a failing drive."
         C_HELP=($"Copy your important files to another place as soon as possible."
            $"Try another cable and connect the device directly to the computer, without a hub."
            $"Check the health of the drive in KDE Partition Manager (SMART status).")
         ;;
      mounted-ro)
         C_TITLE=$"Read-only device"
         C_REASON=$"The filesystem was mounted read-only, but no problem was found with it."
         C_HELP=($"Mount it again with writing enabled.")
         C_FIX_LABEL=$"Mount again with writing"
         C_FIX_INFO=$"The device will be unmounted and mounted again with writing enabled. Nothing on it is changed. Programs using it must be closed first."
         ;;
      permission)
         C_TITLE=$"No permission to write"
         C_REASON=$"The device accepts writing, but its main folder belongs to another user and you are not allowed to change it."
         C_HELP=($"You can become the owner of the main folder. Only that folder changes: the files and folders inside it keep their owners."
            $"This is the usual fix for drives formatted with a Linux filesystem (ext4, Btrfs, XFS).")
         C_FIX_LABEL=$"Become owner of the main folder"
         C_FIX_INFO=$"The main folder of the device will belong to you (not recursive: the files and folders inside keep their owners). The administrator password may be requested."
         ;;
      permission-os)
         C_TITLE=$"No permission to write"
         C_REASON=$"This partition contains an operating system. Its folders belong to that system and must keep their owners."
         C_HELP=($"Save your files in a folder that belongs to you, for example your home folder on that system.")
         ;;
      permission-folder)
         C_TITLE=$"No permission to write"
         printf -v C_REASON $"This folder belongs to %s, and only its owner can create or change files in it." "${D_OWNER:-?}"
         C_HELP=($"Save your files in a folder of your own, for example in your home folder.")
         ;;
      system)
         C_TITLE=$"System partition"
         C_REASON=$"This partition holds the operating system that is running now. Only the system and administrators write here."
         C_HELP=($"Save your files in your home folder.")
         ;;
      swap)
         C_TITLE=$"Swap space"
         C_REASON=$"This partition is used as swap space (virtual memory), not to store files."
         ;;
      permission-other-user)
         C_TITLE=$"No permission to write"
         C_REASON=$"The device was mounted for another user, so only that user can write to it."
         C_HELP=($"Unmount it and open it again from the file manager while you are logged in.")
         if [[ $D_MP == /mnt/* ]]; then
            C_HELP=($"This internal partition is mounted by Big-Mount at boot. An administrator can choose who may write to it with PERMISSIONS in /etc/big-mount.conf.")
         fi
         C_FIX_LABEL=$"Mount again for my user"
         C_FIX_INFO=$"The device will be unmounted and mounted again for your user. Nothing on it is changed. Programs using it must be closed first."
         ;;
      *)
         C_TITLE=$"Unknown state"
         C_REASON=$"The state of this device could not be determined."
         ;;
   esac
}

bsr_fs_label() {
   case "$1" in
      ntfs) REPLY="NTFS" ;; vfat) REPLY="FAT32" ;; exfat) REPLY="exFAT" ;;
      ext4 | ext3 | ext2) REPLY="$1" ;; btrfs) REPLY="Btrfs" ;; xfs) REPLY="XFS" ;;
      f2fs) REPLY="F2FS" ;; iso9660) REPLY="ISO 9660" ;; "") REPLY=$"unknown" ;;
      *) REPLY="$1" ;;
   esac
}

# Turn a diagnosis into the text cause key (permission on an OS partition is
# explained differently)
bsr_cause_key() {
   REPLY="$D_CAUSE"
   if [ "$D_CAUSE" = permission ] && [ -z "$D_FIX" ]; then REPLY=permission-os; fi
}

# The mount point that matters among several: a system one if the device
# holds the running system, otherwise the first that is not a leftover of
# os-prober. MOUNTPOINTS from lsblk are separated by newlines.
bsr_main_mountpoint() {
   local mp first="" sys=""
   while IFS= read -r mp; do
      [ -n "$mp" ] || continue
      [ "$mp" = "[SWAP]" ] && continue
      bsr_is_system_mount "$mp" && { sys="$mp"; break; }
      [[ $mp == /var/lib/os-prober/* ]] && continue
      [ -n "$first" ] || first="$mp"
   done <<< "$1"
   REPLY="${sys:-$first}"
}

# Who mounted it
bsr_manager() {
   local dev="$1" mp="$2"
   if [ -z "$mp" ]; then REPLY=""
   elif bsr_is_system_mount "$mp"; then REPLY=$"system"
   elif findmnt --fstab --source "$dev" >/dev/null 2>&1; then REPLY="fstab"
   elif bsr_boot_status "$dev"; then REPLY="big-storage-rescue"
   elif [[ $mp == /run/media/* || $mp == /media/* ]]; then REPLY="UDisks"
   elif [[ $mp == /mnt/* ]]; then REPLY="big-storage-rescue"
   else REPLY=$"other"
   fi
}

# Build the diagnosis document for the device in F (after bsr_diagnose_write)
bsr_diag_doc() {
   local dev="$1" key mp state
   bsr_cause_key; key="$REPLY"
   bsr_cause_text "$key"
   bsr_doc_new
   bsr_doc_h "$C_TITLE"
   # Essentials only: the title already says the state, the device path is
   # in the technical details
   bsr_display_name; bsr_doc_kv $"Device" "$REPLY"
   bsr_fs_label "${F[FSTYPE]}"; bsr_doc_kv $"Filesystem" "$REPLY"
   mp="$D_MP"
   [ -n "$mp" ] && bsr_doc_kv $"Mounted at" "$mp"
   [ -n "${D_PATH:-}" ] && bsr_doc_kv $"Folder" "$D_PATH"
   case "$D_CAUSE" in
      permission | permission-other-user) state=$"Writable, but not by your user"; bsr_doc_kv $"Status" "$state" ;;
   esac
   bsr_doc_p "$C_REASON"
   if [ "${#C_HELP[@]}" -gt 0 ]; then
      bsr_doc_p $"How to solve:"
      local s; for s in "${C_HELP[@]}"; do bsr_doc_li "$s"; done
   fi
   if [ "${#D_WARN[@]}" -gt 0 ]; then
      bsr_doc_p $"Attention: the filesystem has recorded errors. Copy important files elsewhere and check it soon."
   fi
   if [ "$DH_DISK" = "${F[DISK]:-}" ] && [ "${#DH_FIND[@]}" -gt 0 ]; then
      bsr_doc_p $"Attention: the drive that holds this device reported errors since the computer was started. Copy important files elsewhere and check the drive."
   fi
}

# Health of the drive of the device in F, for the diagnosis of one of its
# filesystems (loop devices and optical drives have nothing to report)
bsr_diag_drive() {
   DH_FIND=() DH_DISK=""
   [ "${F[DISK_TYPE]:-}" = disk ] && bsr_drive_health "${F[DISK]}"
   return 0
}

# Technical report for "Details" and for the terminal
bsr_tech_report() {
   local dev="$1" i l
   printf '%s\n' "device:      $dev (${F[KNAME]}), disk ${F[DISK]}"
   printf '%s\n' "model:       ${F[VENDOR]:+${F[VENDOR]} }${F[MODEL]}"
   printf '%s\n' "transport:   ${F[TRAN]:-?}  removable=${F[RM]} hotplug=${F[HOTPLUG]} ro(part)=${F[RO]} ro(disk)=${F[DISK_RO]}"
   printf '%s\n' "filesystem:  ${F[FSTYPE]} ${F[FSVER]} label='${F[LABEL]}' uuid=${F[UUID]}"
   bsr_mounts "$dev"
   for i in "${!M_TARGET[@]}"; do
      printf '%s\n' "mount:       ${M_TARGET[i]} type=${M_FSTYPE[i]} vfs=${M_VFSOPT[i]} fs=${M_FSOPT[i]}"
   done
   bsr_boot_status "$dev" && printf '%s\n' "big-storage-rescue:   $REPLY"
   printf '%s\n' "diagnosis:   ${D_CAUSE}${D_DETAIL:+ ($D_DETAIL)}${D_FIX:+ fix=$D_FIX}"
   for l in "${D_WARN[@]}"; do printf '%s\n' "warning:     $l"; done
   [ "$DH_DISK" = "${F[DISK]}" ] && [ "${#DH_FIND[@]}" -gt 0 ] &&
      printf '%s\n' "drive:       ${F[DISK]} reported: ${DH_FIND[*]} (big-storage-rescue --diagnose ${F[DISK]})"
   if [ "${#KMSG[@]}" -gt 0 ]; then
      printf '%s\n' "kernel:"
      for l in "${KMSG[@]:$((${#KMSG[@]} > 10 ? ${#KMSG[@]} - 10 : 0))}"; do printf '             %s\n' "$l"; done
   fi
}

# ---------------------------------------------------------------------------
# --diagnose

# Partitions of a whole disk that hold a filesystem (DISK_PARTS)
bsr_disk_parts() {
   local line
   DISK_PARTS=()
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      [ "${KV[NAME]}" = "$1" ] && continue
      case "${KV[FSTYPE]}" in "" | crypto_LUKS | LVM2_member | *_member) continue ;; esac
      DISK_PARTS+=("${KV[NAME]}")
   done < <(lsblk -P -p -n -o NAME,FSTYPE -- "$1" 2>/dev/null)
}

bsr_cmd_diagnose() {
   local target="${1:-}" part rc=0
   declare -F bsr_sc_run >/dev/null || bsr_load system-check.sh
   if [ -z "$target" ]; then
      bsr_overview
      return
   fi
   bsr_resolve "$target" || { bsr_resolve_fail "$target"; return 1; }
   bsr_facts "$R_DEV" || { R_ERR=unavailable; bsr_resolve_fail "$R_DEV"; return 1; }
   # A whole disk: the health of the drive, then each of its filesystems
   if [ "${F[TYPE]}" = disk ] && [ -z "${F[FSTYPE]}" ]; then
      bsr_drive_show "$R_DEV" || rc=1
      bsr_disk_parts "$R_DEV"
      for part in "${DISK_PARTS[@]}"; do
         printf '\n'
         BSR_DRIVE_SHOWN=1 bsr_cmd_diagnose "$part" || rc=1
      done
      return "$rc"
   fi
   bsr_diagnose_write "$R_DEV" "$R_PATH"
   bsr_diag_drive
   bsr_diag_doc "$R_DEV"
   bsr_ui_show info "$C_TITLE"
   if [ "${#DH_FIND[@]}" -gt 0 ] && [ -z "${BSR_DRIVE_SHOWN:-}" ]; then
      printf $"To see the errors of the drive: big-storage-rescue --diagnose %s"'\n' "${F[DISK]}"
   fi
   printf '\n%s\n' $"Technical details:"
   bsr_tech_report "$R_DEV" | sed 's/^/  /'
   # The running system is used by every program and is never removed:
   # listing its users would only be noise
   if [ -n "$D_MP" ] && ! bsr_is_system_mount "$D_MP"; then
      printf '\n'
      bsr_busy_doc "$R_DEV" quiet
      if [ "$BUSY_COUNT" -gt 0 ]; then bsr_ui_show info ""; fi
   fi
   [ "$D_CAUSE" = ok ] || [ "$D_CAUSE" = not-mounted ]
}

# Overview of every filesystem, plus a quick self-check of the environment
bsr_overview() {
   local line dev fstype label size mp state mgr hint=0 rows=() r c out w=() i
   # Header first; column widths come from the longest cell (in characters)
   rows+=($"DEVICE"$'\t'$"LABEL"$'\t'$"SIZE"$'\t'$"FS"$'\t'$"MANAGED BY"$'\t'$"MOUNTED AT"$'\t'$"STATE")
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      dev="${KV[NAME]}" fstype="${KV[FSTYPE]}" label="${KV[LABEL]}"
      bsr_main_mountpoint "${KV[MOUNTPOINTS]}"; mp="$REPLY"
      case "$fstype" in "" | swap | squashfs | crypto_LUKS | LVM2_member | *_member) continue ;; esac
      [ "${KV[TYPE]}" = loop ] && [ -z "$mp" ] && continue
      bsr_human_size "${KV[SIZE]}"; size="$REPLY"
      bsr_manager "$dev" "$mp"; mgr="${REPLY:--}"
      if [ -z "$mp" ]; then
         state=$"not mounted"
      elif bsr_is_system_mount "$mp"; then
         state=$"in use by the system"
      elif findmnt -n -o VFS-OPTIONS --mountpoint "$mp" 2>/dev/null | grep -qE '(^|,)ro(,|$)'; then
         state=$"READ-ONLY"; hint=1
      elif [ -w "$mp" ]; then
         state=$"read and write"
      else
         state=$"no write permission"; hint=1
      fi
      label="${label//[[:cntrl:]]/?}" mp="${mp//[[:cntrl:]]/?}"
      rows+=("$dev"$'\t'"${label:--}"$'\t'"$size"$'\t'"$fstype"$'\t'"$mgr"$'\t'"${mp:--}"$'\t'"$state")
   done < <(lsblk -P -b -p -o NAME,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS 2>/dev/null)
   # Long labels and mount points are shortened (…), never cut mid-character
   local max=(24 20 9 8 16 40 0)
   for r in "${rows[@]}"; do
      IFS=$'\t' read -r -a c <<< "$r"
      for i in 0 1 2 3 4 5; do
         [ "${#c[i]}" -gt "${w[i]:-0}" ] && w[i]="${#c[i]}"
         [ "${w[i]}" -gt "${max[i]}" ] && w[i]="${max[i]}"
      done
   done
   printf '%s\n\n' $"Storage devices"
   for r in "${rows[@]}"; do
      IFS=$'\t' read -r -a c <<< "$r"
      out=" "
      for i in 0 1 2 3 4 5; do
         if [ "$i" -eq 2 ]; then
            # Sizes are right-aligned
            printf -v line '%*s' $((w[i] - ${#c[i]})) ""; out+=" $line${c[i]}"
         else
            bsr_pad "${c[i]}" "${w[i]}"; out+=" $REPLY"
         fi
      done
      printf '%s %s\n' "$out" "${c[6]}"
   done
   [ "$hint" -eq 1 ] && printf '\n%s\n' $"To find out why a device cannot be written to, run: big-storage-rescue --diagnose DEVICE"

   # Only the drives of the running system: the free space of the others is
   # their owner's business
   bsr_sc_run
   # shellcheck disable=SC2153  # SC_* come from system-check.sh
   if [ "${#SC_KEY[@]}" -gt 0 ]; then
      printf '\n%s\n' $"Running system"
      for i in "${!SC_KEY[@]}"; do
         printf '  %s\n' "${SC_TEXT[i]}"
         printf '%s\n' "${SC_HELP[i]}" | fold -s -w 76 | sed 's/^/    /'
      done
   fi

   printf '\n%s\n' $"Environment"
   local s
   # Big-Mount mounts the internal partitions at boot; optional
   s="$(systemctl is-enabled big-mount.service 2>/dev/null)"; printf '  %-28s %s\n' "big-mount.service" "${s:-$"not installed"}"
   [ -e /etc/bigmountall-no ] && printf '  %-28s %s\n' "/etc/bigmountall-no" $"present: automount disabled"
   if busctl --system --no-pager status org.freedesktop.UDisks2 >/dev/null 2>&1; then s=$"available"; else s=$"not available"; fi
   printf '  %-28s %s\n' "UDisks2" "$s"
   for s in lsof python3 notify-send; do
      if command -v "$s" >/dev/null; then printf '  %-28s %s\n' "$s" $"installed"; else printf '  %-28s %s\n' "$s" $"missing"; fi
   done
   if journalctl -k -b -n 1 -q >/dev/null 2>&1 && [ -n "$(journalctl -k -b -n 1 -q 2>/dev/null)" ]; then s=$"readable"; else s=$"not readable (fewer details for errors)"; fi
   printf '  %-28s %s\n' $"kernel log" "$s"
}

# ---------------------------------------------------------------------------
# What keeps a device busy

# bsr_busy_collect DEV [LSOF_FILE]: processes and other users of every mount
# of DEV. Fills the BUSY_* arrays and BUSY_COUNT.
bsr_busy_collect() {
   local dev="$1" src="${2:-}" mp i
   BUSY_PID=() BUSY_UID=() BUSY_USER=() BUSY_COMM=() BUSY_APP=() BUSY_FD=() BUSY_ACCESS=() BUSY_PATH=() BUSY_START=() BUSY_STATE=()
   BUSY_PIDS=()
   bsr_mounts "$dev"
   local mps=("${M_TARGET[@]}")
   for mp in "${mps[@]}"; do
      bsr_holders "$mp" "$src"
      for i in "${!H_PID[@]}"; do
         BUSY_PID+=("${H_PID[i]}") BUSY_UID+=("${H_UID[i]}") BUSY_USER+=("${H_USER[i]}")
         BUSY_COMM+=("${H_COMM[i]}") BUSY_APP+=("${H_APP[i]}") BUSY_FD+=("${H_FD[i]}")
         BUSY_ACCESS+=("${H_ACCESS[i]}") BUSY_PATH+=("${H_PATH[i]}") BUSY_START+=("${H_START[i]}")
         BUSY_STATE+=("${H_STATE[i]}")
      done
      for i in "${H_PIDS[@]}"; do [[ " ${BUSY_PIDS[*]} " == *" $i "* ]] || BUSY_PIDS+=("$i"); done
   done
   bsr_other_holders "$dev"
   BUSY_COUNT=$((${#BUSY_PIDS[@]} + ${#O_KIND[@]}))
}

# Present a BUSY collection through the bsr_holders arrays (for close checks)
bsr_busy_as_holders() {
   H_PID=("${BUSY_PID[@]}") H_UID=("${BUSY_UID[@]}") H_COMM=("${BUSY_COMM[@]}")
   H_ACCESS=("${BUSY_ACCESS[@]}")
}

bsr_other_label() {
   case "$1" in
      mount) printf -v REPLY $"Also mounted at %s" "$2" ;;
      nested) printf -v REPLY $"Another device is mounted inside it: %s" "$2" ;;
      swapfile) printf -v REPLY $"A swap file on it is in use: %s" "$2" ;;
      swap) REPLY=$"It is in use as swap space" ;;
      loop) printf -v REPLY $"A disk image stored on it is attached: %s" "$2" ;;
      holder) printf -v REPLY $"It is used by %s (encryption, LVM or RAID)" "$2" ;;
      isolated) printf -v REPLY $"Also mounted inside an isolated environment (a container or a sandboxed service): %s" "$2" ;;
      *) REPLY="$2" ;;
   esac
}

# Plain-language summary of a BUSY collection, from the holder that matters
# most to the user: something writing, a terminal, a file manager, an
# indexer, anything else. Sets BUSY_SUMMARY and BUSY_ADVICE.
bsr_busy_summary() {
   local i best=0 rank=0 r comm app n="${#BUSY_PIDS[@]}"
   BUSY_SUMMARY="" BUSY_ADVICE=""
   # Priority of a holder: 6 writing, 5 shell/terminal, 4 file manager,
   # 3 indexer, 2 another program whose current folder is on the device, 1 other
   for i in "${!BUSY_PID[@]}"; do
      comm="${BUSY_COMM[i]}" r=1
      case "$comm" in
         dolphin | kioworker* | kioslave* | nautilus | nemo | thunar | pcmanfm* | caja | krusader | doublecmd) r=4 ;;
         baloo_file* | baloorunner | tracker-* | localsearch*) r=3 ;;
      esac
      if [[ $BSR_SHELL_COMM == *" $comm "* ]]; then
         r=5
      elif [ "$r" -eq 1 ] && [ "${BUSY_FD[i]}" = cwd ]; then
         r=2
      fi
      if [ "${BUSY_ACCESS[i]}" = w ] || [ "${BUSY_ACCESS[i]}" = u ]; then r=6; fi
      if [ "$r" -gt "$best" ]; then best="$r" rank="$i"; fi
   done
   if [ "$best" -eq 0 ]; then
      if [[ " ${O_KIND[*]} " =~ ^( isolated)+\ $ ]]; then
         BUSY_SUMMARY=$"A container or a sandboxed service has its own mount of this device (see below). Unmounting it here does not release the device while that mount exists."
         BUSY_ADVICE=$"Stop that container or service first. Big Storage Rescue waits for it before saying the device can be disconnected."
      elif [ "${#O_KIND[@]}" -gt 0 ]; then
         BUSY_SUMMARY=$"No program is using it, but the system still is (see below)."
         BUSY_ADVICE=$"Resolve the item listed below, then try again."
      else
         BUSY_SUMMARY=$"None of your programs is using it. A system service or a program of another user may be holding it, or it was released a moment ago."
         BUSY_ADVICE=$"Try again. If it is still busy, show the programs of all users."
      fi
      return 0
   fi
   app="${BUSY_APP[rank]}"
   case "$best" in
      6) printf -v BUSY_SUMMARY $"%s has a file open for writing on this device." "$app"
         BUSY_ADVICE=$"Let it finish, or cancel the operation in that program, then try again." ;;
      5) BUSY_SUMMARY=$"A terminal is open in a folder of this device."
         BUSY_ADVICE=$"Type cd in that terminal, or close it, then try again." ;;
      4) printf -v BUSY_SUMMARY $"%s is showing or reading files of this device." "$app"
         BUSY_ADVICE=$"Close the window or tab that shows the device, then try again." ;;
      3) BUSY_SUMMARY=$"The file indexer is reading this device."
         BUSY_ADVICE=$"It usually finishes in a moment: try again shortly." ;;
      2) printf -v BUSY_SUMMARY $"%s is running inside a folder of this device." "$app"
         BUSY_ADVICE=$"Close that program, then try again." ;;
      *) printf -v BUSY_SUMMARY $"%s is using files on this device." "$app"
         BUSY_ADVICE=$"Close that program, then try again." ;;
   esac
   if [ "$n" -gt 1 ]; then
      printf -v r $"In total, %d programs are using it." "$n"
      BUSY_SUMMARY+=" $r"
   fi
}

# bsr_busy_doc DEV [quiet] [privileged]: document describing what keeps DEV busy
bsr_busy_doc() {
   local dev="$1" mode="${2:-}" priv="${3:-}" i key shown=() access
   bsr_busy_collect "$dev" "${BSR_PRIV_LSOF:-}"
   bsr_facts "$dev"
   bsr_doc_new
   if [ "$mode" = quiet ]; then
      [ "$BUSY_COUNT" -gt 0 ] || return 0
      bsr_doc_h $"In use"
   else
      bsr_busy_summary
      bsr_short_name
      printf -v key $"%s is still in use" "$REPLY"
      bsr_doc_h "$key"
      bsr_doc_p "$BUSY_SUMMARY"
      bsr_doc_p "$BUSY_ADVICE"
      bsr_display_name; bsr_doc_kv $"Device" "$REPLY"
      bsr_fs_label "${F[FSTYPE]}"; bsr_doc_kv $"Filesystem" "$REPLY"
      bsr_mounts "$dev"; [ "${#M_TARGET[@]}" -gt 0 ] && bsr_doc_kv $"Mounted at" "${M_TARGET[0]}"
      key=""
   fi
   if [ "${#BUSY_PIDS[@]}" -gt 0 ]; then
      bsr_doc_p $"Programs using it:"
      if [ -n "$priv" ]; then
         bsr_doc_th $"Application"$'\n'$"process" "PID" $"User" $"Activity"
      else
         bsr_doc_th $"Application"$'\n'$"process" "PID" $"Activity"
      fi
      for i in "${!BUSY_PID[@]}"; do
         bsr_access_label "${BUSY_FD[i]}" "${BUSY_ACCESS[i]}" ""
         access="$REPLY"
         key="${BUSY_PID[i]}|$access"
         [[ " ${shown[*]} " == *" $key "* ]] && continue
         shown+=("$key")
         if [ -n "$priv" ]; then
            bsr_doc_tr "${BUSY_APP[i]}"$'\n'"${BUSY_COMM[i]}" "${BUSY_PID[i]}" "${BUSY_USER[i]:-${BUSY_UID[i]}}" "$access"
         else
            bsr_doc_tr "${BUSY_APP[i]}"$'\n'"${BUSY_COMM[i]}" "${BUSY_PID[i]}" "$access"
         fi
      done
   fi
   if [ "${#O_KIND[@]}" -gt 0 ]; then
      bsr_doc_p $"Also keeping it busy:"
      for i in "${!O_KIND[@]}"; do bsr_other_label "${O_KIND[i]}" "${O_WHAT[i]}"; bsr_doc_li "$REPLY"; done
   fi
   [ "$mode" = quiet ] && return 0
   [ "${#BUSY_PIDS[@]}" -gt 0 ] && bsr_doc_p $"An open file does not necessarily mean that something is being copied."
   return 0
}

bsr_busy_details_file() {
   local f="$1" i
   {
      printf '%s\n' "$(bsr_tech_report "$2" 2>/dev/null)"
      printf '\n%s\n' "open files:"
      for i in "${!BUSY_PID[@]}"; do
         printf '  pid=%s user=%s state=%s comm=%s fd=%s access=%s\n      %s\n' \
            "${BUSY_PID[i]}" "${BUSY_USER[i]:-${BUSY_UID[i]}}" "${BUSY_STATE[i]}" "${BUSY_COMM[i]}" \
            "${BUSY_FD[i]}" "${BUSY_ACCESS[i]:--}" "${BUSY_PATH[i]//[[:cntrl:]]/?}"
      done
      for i in "${!O_KIND[@]}"; do printf '  %s: %s\n' "${O_KIND[i]}" "${O_WHAT[i]}"; done
   } > "$f"
}

bsr_cmd_busy() {
   bsr_resolve "${1:-}" || { bsr_resolve_fail "${1:-}"; return 1; }
   bsr_busy_doc "$R_DEV"
   if [ "$BUSY_COUNT" -eq 0 ]; then
      # Nothing visible holds it: say so instead of "still in use". A user
      # cannot see the programs of other users, so only root may say "nothing"
      bsr_short_name
      bsr_doc_new
      if [ "$EUID" -eq 0 ]; then
         printf -v REPLY $"%s is not in use" "$REPLY"
         bsr_doc_h "$REPLY"
         bsr_doc_p $"No program and nothing in the system is using it. It can be unmounted."
      else
         printf -v REPLY $"None of your programs is using %s" "$REPLY"
         bsr_doc_h "$REPLY"
         bsr_doc_p $"No program of yours, no other mount and no other device is using it. It can probably be unmounted. Programs of other users and of the system are only visible to an administrator."
      fi
      bsr_ui_show info ""
      return 0
   fi
   bsr_ui_show info ""
   return 3
}

# ---------------------------------------------------------------------------
# Safe removal

# bsr_remove_core MODE DEV: MODE "unmount" (one filesystem), "drive" (every
# filesystem of the drive) or "remove" (every filesystem, then lock its
# encrypted volumes and power it off when it is a removable drive). Returns the exit
# codes documented at the top.
# RM_BUSY_DEV, RM_REASON, RM_POWERED and RM_REMOVABLE describe the outcome;
# RM_GONE=1 when it stopped because the device disappeared (unplugged, or
# replaced by another one under the same name).
#
# Before every step that cannot be undone the disk sequence number is checked
# again (another device may have taken the name), and nothing is reported as
# safe while any filesystem of the drive is still mounted.
bsr_remove_core() {
   local mode="$1" dev="$2" d i t targets=() types=() rc seq n
   RM_BUSY_DEV="" RM_REASON="" RM_POWERED=0 RM_REMOVABLE=0 RM_GONE=0 RM_DEP_UNITS=() RM_DEP_NAMES=() RM_DEP_BACK=()
   _bsr_gone() {
      RM_GONE=1
      RM_REASON=$"The device was disconnected or replaced during the operation. Nothing else was done."
   }
   bsr_facts "$dev" || { _bsr_gone; return 1; }
   local disk="${F[DISK]}" disk_type="${F[DISK_TYPE]}"
   bsr_is_removable_drive && RM_REMOVABLE=1
   bsr_diskseq "$disk"; seq="$REPLY"
   _bsr_same_disk() {
      bsr_diskseq "$disk"
      # Kernels before 5.15 have no diskseq: then at least the node must exist
      [ "$REPLY" = "$seq" ] && { [ -n "$seq" ] || [ -b "$disk" ]; } && return 0
      _bsr_gone
      return 1
   }
   if [ "$mode" != unmount ]; then
      if bsr_system_use "$disk"; then RM_REASON="$REPLY"; return 4; fi
      bsr_drive_members "$disk"
      targets=("${DRIVE_DEVS[@]}") types=("${DRIVE_FSTYPES[@]}")
   else
      bsr_mounts "$dev"
      for t in "${M_TARGET[@]}"; do
         bsr_is_system_mount "$t" && { RM_REASON="$dev → $t"; return 4; }
      done
      targets=("$dev")
   fi
   # Services that systemd stops when these mounts go away (e.g. a media or
   # photo server with BindsTo= on the mount): never stop them by surprise.
   # The caller asks the user and sets RM_ALLOW_SERVICES=1 to go on.
   if [ "${RM_ALLOW_SERVICES:-0}" != 1 ]; then
      for d in "${targets[@]}"; do
         bsr_mounts "$d"
         for t in "${M_TARGET[@]}"; do
            bsr_mount_dependents "$t"
            RM_DEP_UNITS+=("${DEP_UNITS[@]}") RM_DEP_NAMES+=("${DEP_NAMES[@]}") RM_DEP_BACK+=("${DEP_BACK[@]}")
         done
      done
      [ "${#RM_DEP_UNITS[@]}" -gt 0 ] && return 9
   fi

   # Stacked devices (LUKS, LVM) come after their parents in lsblk: go backwards
   for ((i = ${#targets[@]} - 1; i >= 0; i--)); do
      d="${targets[i]}"
      bsr_mounts "$d"
      [ "${#M_TARGET[@]}" -eq 0 ] && continue
      _bsr_same_disk || return 1
      if ! bsr_unmount_all "$d"; then
         case "$UD_ERROR" in
            *DeviceBusy*) RM_BUSY_DEV="$d"; return 3 ;;
            *NotAuthorized*) return 5 ;;
            no-object) _bsr_gone; return 1 ;;
            *) RM_REASON="$UD_MESSAGE"; return 1 ;;
         esac
      fi
   done
   [ "$mode" = unmount ] && return 0

   # Nothing may have been mounted again meanwhile (an automounter, a script)
   for d in "${targets[@]}"; do
      bsr_mounts "$d"
      if [ "${#M_TARGET[@]}" -gt 0 ]; then
         printf -v RM_REASON $"%s was mounted again at %s" "$d" "${M_TARGET[0]}"
         return 1
      fi
   done
   [ "$mode" = remove ] || return 0

   # Lock encrypted volumes that are open (their filesystems are unmounted
   # by now), as the Plasma device notifier does before a safe removal
   for i in "${!targets[@]}"; do
      [ "${types[i]}" = crypto_LUKS ] || continue
      d="${targets[i]}"
      bsr_has_holders "$d" || continue
      _bsr_same_disk || return 1
      if ! bsr_udisks lock -b "$d"; then
         [[ $UD_ERROR == *NotAuthorized* ]] && return 5
         [ "$UD_ERROR" = no-object ] && { _bsr_gone; return 1; }
         printf -v RM_REASON $"%s: the encrypted volume could not be locked" "$d"
         return 6
      fi
   done

   # Internal disks are unmounted, never powered off
   [ "$RM_REMOVABLE" = 1 ] || return 0

   # Nothing may use the drive any more before it is powered off
   for d in "${targets[@]}"; do
      bsr_other_holders "$d"
      for i in "${!O_KIND[@]}"; do
         if [ "${O_KIND[i]}" = holder ] || [ "${O_KIND[i]}" = swap ]; then
            bsr_other_label "${O_KIND[i]}" "${O_WHAT[i]}"; RM_REASON="$d: $REPLY"; return 6
         fi
      done
   done
   [ "$disk_type" = loop ] && return 7
   # A few attempts: right after an unmount, udev and UDisks may still be
   # processing the change and report the drive as in use
   for ((n = 0; n < 3; n++)); do
      _bsr_same_disk || return 1
      if bsr_udisks power-off -b "$disk"; then
         RM_POWERED=1
         return 0
      fi
      case "$UD_ERROR" in
         *NotAuthorized*) return 5 ;;
         *NotSupported*) RM_REASON="$UD_MESSAGE"; return 7 ;;
         no-object) _bsr_gone; return 1 ;;
      esac
      udevadm settle --timeout=5 >/dev/null 2>&1
      sleep 1
   done
   # Unmounted, but the power-off itself failed: say so, with the reason
   RM_REASON="${UD_MESSAGE##*: }"
   return 8
}

# What happens to the services of RM_DEP_* once the device is back (REPLY)
bsr_dep_restart_text() {
   if [[ " ${RM_DEP_BACK[*]} " == *" 0 "* ]]; then
      REPLY=$"They do not start again by themselves when the device comes back."
   else
      REPLY=$"They start again by themselves when the device is mounted again."
   fi
}

# Eligible processes to close: CLOSE_PIDS/CLOSE_STARTS/CLOSE_NAMES, others in KEEP_*
bsr_close_candidates() {
   local i pid
   local -A seen_pid=()
   CLOSE_PIDS=() CLOSE_STARTS=() CLOSE_NAMES=() KEEP_NAMES=() KEEP_WHY=()
   bsr_busy_as_holders
   for i in "${!BUSY_PID[@]}"; do
      pid="${BUSY_PID[i]}"
      [ -n "${seen_pid[$pid]:-}" ] && continue
      seen_pid[$pid]=1
      if bsr_close_refusal "$i"; then
         CLOSE_PIDS+=("$pid") CLOSE_STARTS+=("${BUSY_START[i]}") CLOSE_NAMES+=("${BUSY_APP[i]} (${BUSY_COMM[i]}, PID $pid)")
      else
         KEEP_NAMES+=("${BUSY_APP[i]} (${BUSY_COMM[i]}, PID $pid)") KEEP_WHY+=("$REPLY")
      fi
   done
}

bsr_close_args() {
   local i
   CLOSE_ARGS=()
   for i in "${!CLOSE_PIDS[@]}"; do CLOSE_ARGS+=("${CLOSE_PIDS[i]}" "${CLOSE_STARTS[i]}"); done
}

bsr_cmd_remove() {
   local mode="$1" target="" close=0 yes=0 a rc
   shift
   RM_ALLOW_SERVICES=0
   for a in "$@"; do
      case "$a" in
         --close-apps) close=1 ;;
         --assume-yes) yes=1 ;;
         --no-power-off) [ "$mode" = remove ] && mode=drive ;;
         -*) printf $"big-storage-rescue: unknown option '%s' (see big-storage-rescue --help)"'\n' "$a" >&2; return 2 ;;
         *) target="$a" ;;
      esac
   done
   bsr_resolve "$target" || { bsr_resolve_fail "$target"; return 1; }
   if bsr_facts "$R_DEV" && ! bsr_drive_lock "${F[DISK]}"; then
      printf '%s\n' $"Another removal of this drive is in progress. Nothing was done." >&2
      return 10
   fi
   bsr_remove_tty "$mode" "$R_DEV" "$close" "$yes"; rc=$?
   bsr_drive_unlock
   return "$rc"
}

# The terminal dialogue of bsr_cmd_remove, with the drive locked
bsr_remove_tty() {
   local mode="$1" dev="$2" close="$3" yes="$4" a rc tries=0
   while :; do
      bsr_remove_core "$mode" "$dev"; rc=$?
      case "$rc" in
         0)
            if [ "$RM_POWERED" = 1 ]; then
               printf '%s\n' $"Device removed safely. It can be disconnected now."
            else
               printf '%s\n' $"Unmounted. Everything was written to the device."
            fi
            return 0
            ;;
         3)
            bsr_busy_doc "$RM_BUSY_DEV"
            bsr_ui_show warning ""
            [ "$close" -eq 1 ] && [ "$tries" -eq 0 ] || return 3
            tries=1
            bsr_close_candidates
            for a in "${!KEEP_NAMES[@]}"; do printf '  %s: %s\n' "${KEEP_NAMES[a]}" "${KEEP_WHY[a]}"; done
            [ "${#CLOSE_PIDS[@]}" -gt 0 ] || return 3
            printf '%s\n' $"These programs can be asked to close (unsaved changes in them may be lost):"
            printf '  %s\n' "${CLOSE_NAMES[@]}"
            if [ "$yes" -eq 0 ]; then
               bsr_doc_new
               bsr_ui_confirm "" "" $"Close them" $"Cancel" || return 3
            fi
            bsr_close_args
            bsr_close_processes "${CLOSE_ARGS[@]}" || printf $"Still running: %s"'\n' "${CLOSE_LEFT[*]}"
            ;;
         9)
            printf '%s\n' $"These services use the device and will be stopped when it is unmounted:" >&2
            for a in "${!RM_DEP_UNITS[@]}"; do printf '  %s (%s)\n' "${RM_DEP_NAMES[a]}" "${RM_DEP_UNITS[a]}" >&2; done
            bsr_dep_restart_text; printf '%s\n' "$REPLY" >&2
            if [ "$yes" -eq 1 ]; then
               RM_ALLOW_SERVICES=1
            elif [ -t 0 ]; then
               bsr_doc_new
               bsr_ui_confirm "" "" $"Stop them and continue" $"Cancel" || return 9
               RM_ALLOW_SERVICES=1
            else
               printf '%s\n' $"Nothing was done. Run again with --assume-yes to stop them." >&2
               return 9
            fi
            ;;
         8) printf $"Unmounted, but powering the drive off failed (%s). Wait a moment before disconnecting it."'\n' "$RM_REASON" >&2; return 8 ;;
         4) printf $"Refused: this drive holds the running system (%s)."'\n' "$RM_REASON" >&2; return 4 ;;
         5) printf '%s\n' $"Permission to unmount was not granted." >&2; return 5 ;;
         6) printf $"Unmounted, but the drive is still in use (%s), so it was not powered off."'\n' "$RM_REASON" >&2; return 6 ;;
         7) printf '%s\n' $"Unmounted. This drive cannot be powered off by the computer; it can be disconnected now." ; return 7 ;;
         *)
            if [ "$RM_GONE" = 1 ]; then printf '%s\n' "$RM_REASON" >&2
            else printf $"Could not unmount: %s"'\n' "$RM_REASON" >&2
            fi
            return 1
            ;;
      esac
   done
}

# ---------------------------------------------------------------------------
# Drive health

bsr_tran_label() {
   case "$1" in
      sata) REPLY="SATA" ;; ata) REPLY="ATA" ;; nvme) REPLY="NVMe" ;; usb) REPLY="USB" ;;
      mmc) REPLY="SD/MMC" ;; "") REPLY=$"unknown" ;; *) REPLY="$1" ;;
   esac
}

# The drive document (DT_TITLE) for F, the whole disk, after bsr_drive_health
bsr_drive_doc() {
   local k s
   if [ "${#DH_FIND[@]}" -gt 0 ]; then DT_TITLE=$"The drive reports errors"
   elif [ "${DHI_PAST:-0}" = 1 ] || [ "${FSE_TOTAL:-0}" -gt 0 ]; then DT_TITLE=$"The drive had errors before this start of the computer"
   else DT_TITLE=$"No drive errors found"
   fi
   bsr_doc_new
   bsr_doc_h "$DT_TITLE"
   bsr_display_name; bsr_doc_kv $"Drive" "$REPLY"
   bsr_tran_label "${F[TRAN]:-}"; bsr_doc_kv $"Connection" "$REPLY"
   case "$DH_SMART" in
      ok) s=$"no problem reported" ;;
      failing) s=$"the drive predicts its own failure" ;;
      *) s=$"not available" ;;
   esac
   if [ "$DH_SMART" = ok ] && [ "$DH_BAD" -gt 0 ]; then
      printf -v s $"no failure predicted (%s damaged sectors were replaced by spare ones)" "$DH_BAD"
   fi
   bsr_doc_kv $"SMART status" "$s"
   if [ "${#DH_FIND[@]}" -eq 0 ]; then
      if [ "$DH_KLOG" = 1 ]; then
         bsr_doc_p $"Since the computer was started, the system recorded no read, write or connection errors for this drive."
      else
         bsr_doc_p $"The kernel log cannot be read by your user, so recent errors of this drive cannot be checked."
      fi
      bsr_drive_doc_past
      return 0
   fi
   bsr_doc_p $"Problems found:"
   for k in "${DH_FIND[@]}"; do
      case "$k" in
         smart-failing) bsr_doc_li $"The drive itself reports that it is failing (SMART)." ;;
         timeouts) printf -v s $"Since the computer was started, it stopped answering and the connection had to be reset (%s kernel messages)." "${DH_COUNT[$k]}"; bsr_doc_li "$s" ;;
         io-errors) printf -v s $"Since the computer was started, reading or writing failed (%s kernel messages)." "${DH_COUNT[$k]}"; bsr_doc_li "$s" ;;
         slow-link) bsr_doc_li $"Since the computer was started, the connection was slowed down after errors." ;;
         usb-resets) printf -v s $"Since the computer was started, the USB connection was reset or lost %s times." "${DH_COUNT[$k]}"; bsr_doc_li "$s" ;;
      esac
   done
   bsr_doc_p $"How to solve:"
   bsr_doc_li $"Copy your important files to another place as soon as possible."
   [ "${F[TRAN]:-}" = sata ] && bsr_doc_li $"Check the data and power cables of the drive, or try another SATA port."
   [ "$DH_ATA" = 1 ] && bsr_doc_li $"An SSD that fails like this may lock itself in a protection mode: it seems to accept writing, but keeps nothing. Copy what you can first; no repair is worth more than your files."
   bsr_doc_li $"If the errors come back, replace the drive."
   bsr_drive_doc_past
}

# What stays from before this start (after bsr_drive_past): errors of earlier
# starts of an internal drive and the counters of its filesystems
bsr_drive_doc_past() {
   local s
   [ "${DHI_PAST:-0}" = 1 ] || [ "${FSE_TOTAL:-0}" -gt 0 ] || return 0
   bsr_doc_p $"From before this start of the computer:"
   if [ "$DHI_PAST" = 1 ]; then
      printf -v s $"In %s of the last %s starts of the computer, the drive had read or connection errors (%s kernel messages)." "$DHI_BAD" "$DHI_BOOTS" "$DHI_COUNT"
      bsr_doc_li "$s"
      if [ "$DHI_LINK" -gt 0 ] && [ "$DHI_IO" -eq 0 ]; then
         bsr_doc_li $"They were errors of the connection: check the data cable and the power connector of the drive, or try another port."
      fi
   fi
   if [ "$FSE_TOTAL" -gt 0 ]; then
      printf -v s $"Its filesystems recorded %s errors, which are kept across restarts (%s)." "$FSE_TOTAL" "$(IFS=';'; printf '%s' "${FSE_LIST[*]}")"
      bsr_doc_li "${s//;/; }"
      bsr_doc_li $"After the cause is solved (a cable, a drive replaced, the files copied), an administrator can reset them: btrfs device stats -z on Btrfs; e2fsck clears them on ext4."
   fi
}

# Technical report of the drive (F, after bsr_drive_health)
bsr_drive_report() {
   local k l counts=""
   printf '%s\n' "drive:       ${F[DISK]} model='${F[VENDOR]:+${F[VENDOR]} }${F[MODEL]}' transport=${F[TRAN]:-?} port=${DH_PORT:--}"
   printf '%s\n' "smart:       ${DH_SMART:-n/a} bad-sectors=$DH_BAD"
   printf '%s\n' "ata:         ata=$DH_ATA"
   if [ "$DH_KLOG" = 1 ]; then
      for k in timeouts io-errors slow-link usb-resets; do counts+="${counts:+ }$k=${DH_COUNT[$k]:-0}"; done
      printf '%s\n' "kernel log:  $counts"
      for l in "${DH_LINES[@]:$((${#DH_LINES[@]} > 15 ? ${#DH_LINES[@]} - 15 : 0))}"; do printf '             %s\n' "$l"; done
   else
      printf '%s\n' "kernel log:  not readable"
   fi
   if [ "${DHI_BOOTS:-0}" -gt 0 ]; then
      printf '%s\n' "earlier:     starts=$DHI_BOOTS with-errors=$DHI_BAD messages=$DHI_COUNT read=$DHI_IO link=$DHI_LINK"
      for l in "${DHI_LINES[@]}"; do printf '             %s\n' "$l"; done
   fi
   for l in "${FSE_LIST[@]:-}"; do [ -n "$l" ] && printf '%s\n' "fs errors:   $l"; done
}

# big-storage-rescue --diagnose DISK: the health of the drive. Fails when it reported errors.
bsr_drive_show() {
   local disk="$1"
   bsr_drive_health "$disk"
   bsr_drive_past "$disk"
   bsr_drive_doc
   bsr_sc_run "$disk"
   bsr_sc_doc "$SC_SYSTEM"
   bsr_ui_show info "$DT_TITLE"
   printf '\n%s\n' $"Technical details:"
   bsr_drive_report | sed 's/^/  /'
   [ "${#DH_FIND[@]}" -eq 0 ] && [ "$DHI_PAST" = 0 ] && [ "$FSE_TOTAL" -eq 0 ] && [ "${#SC_KEY[@]}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Graphical diagnosis (big-storage-rescue --gui-diagnose)

bsr_pick_device() {
   local line items=() dev label mp
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      dev="${KV[NAME]}" label="${KV[LABEL]}"
      bsr_main_mountpoint "${KV[MOUNTPOINTS]}"; mp="$REPLY"
      case "${KV[FSTYPE]}" in "" | swap | squashfs | crypto_LUKS | LVM2_member | *_member) continue ;; esac
      [ -n "$mp" ] && bsr_is_system_mount "$mp" && continue
      [ "${KV[TYPE]}" = loop ] && [ -z "$mp" ] && continue
      bsr_human_size "${KV[SIZE]}"
      items+=("$dev" "${label:-${dev##*/}} — $REPLY ${KV[FSTYPE]}${mp:+ — $mp}")
   done < <(lsblk -P -b -p -o NAME,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS 2>/dev/null)
   if [ "${#items[@]}" -eq 0 ]; then
      bsr_notify info big-storage-rescue $"Storage diagnostics" $"No storage device to diagnose was found."
      return 1
   fi
   bsr_ui_menu $"Storage diagnostics" $"Choose a device:" "${items[@]}"
   [ -n "$REPLY" ]
}

# bsr_gui_target TARGET TITLE TEXT: resolve TARGET for a graphical command,
# setting R_DEV, R_PATH and F. A folder that is not on a local device is a
# fact, not a failure: a notification (TITLE, TEXT) says so. A device that
# cannot be found (unplugged, not ready yet) gets a dialog that can try
# again and show the technical reason.
bsr_gui_target() {
   local target="$1" tmp
   while :; do
      if bsr_resolve "$target"; then
         bsr_facts "$R_DEV" && return 0
         R_ERR=unavailable
      fi
      if [ "$R_ERR" = not-local ]; then
         bsr_notify info big-storage-rescue "$2" "$3"
         return 1
      fi
      bsr_doc_new
      bsr_doc_h $"Unable to access storage device"
      bsr_doc_p $"Big Storage Rescue could not identify this storage device. It may have been disconnected or become temporarily unavailable."
      bsr_doc_p $"If you disconnected it, connect it again and choose Try again."
      bsr_ui_choice $"Unable to access storage device" dialog-warning $"Try again" $"Technical details" $"Close"
      case "$REPLY" in
         1) ;;
         2)
            tmp="$(mktemp)" || return 1
            bsr_resolve_message "$target"
            printf '%s\n' "target: $target" "node:   ${R_NODE:--}" "reason: ${R_ERR:-?}" "" "$REPLY" > "$tmp"
            bsr_ui_text $"Technical details" "$tmp"; rm -f -- "$tmp"
            ;;
         *) return 1 ;;
      esac
   done
}

bsr_gui_diagnose() {
   local target="${1:-}" key icon tmp
   if [ -z "$target" ]; then
      bsr_pick_device || return 0
      target="$REPLY"
   fi
   bsr_gui_target "$target" $"Storage diagnostics" $"This folder is not on a local storage device." || return 1
   local dev="$R_DEV" path="$R_PATH"
   # A whole disk: its only filesystem, or let the user choose one
   if [ "${F[TYPE]}" = disk ] && [ -z "${F[FSTYPE]}" ]; then
      bsr_disk_parts "$dev"
      if [ "${#DISK_PARTS[@]}" -eq 1 ]; then
         dev="${DISK_PARTS[0]}"
      elif [ "${#DISK_PARTS[@]}" -gt 1 ]; then
         local items=() p
         for p in "${DISK_PARTS[@]}"; do bsr_facts "$p"; bsr_display_name; items+=("$p" "$REPLY"); done
         bsr_ui_menu $"Storage diagnostics" $"Choose a device:" "${items[@]}"
         [ -n "$REPLY" ] || return 0
         dev="$REPLY"
      fi
   fi
   while :; do
      # The device may have been unplugged while a dialog was open
      if ! bsr_facts "$dev"; then
         bsr_gui_target "$dev" $"Storage diagnostics" "" || return 1
      fi
      bsr_diagnose_write "$dev" "$path"
      bsr_diag_drive
      bsr_diag_doc "$dev"
      bsr_device_icon; icon="$REPLY"
      [ "$D_CAUSE" = ok ] && [ "${#DH_FIND[@]}" -eq 0 ] || icon=dialog-warning
      if [ -n "$D_FIX" ]; then
         bsr_ui_choice "$C_TITLE" "$icon" "$C_FIX_LABEL" $"Technical details" $"Close"
      elif [ "${#DH_FIND[@]}" -gt 0 ]; then
         bsr_ui_choice "$C_TITLE" "$icon" $"Check the drive…" $"Technical details" $"Close"
         [ "$REPLY" = 1 ] && REPLY=5
      elif bsr_is_removable_drive && [ -n "$D_MP" ]; then
         bsr_ui_choice "$C_TITLE" "$icon" $"Technical details" $"Safely remove…" $"Close"
         case "$REPLY" in 1) REPLY=2 ;; 2) REPLY=4 ;; esac
      elif bsr_ui_confirm "$C_TITLE" "$icon" $"Technical details" $"Close"; then
         REPLY=2
      else
         REPLY=3
      fi
      case "$REPLY" in
         1) bsr_gui_fix "$dev" ;;
         2)
            tmp="$(mktemp)"; bsr_tech_report "$dev" > "$tmp"
            bsr_ui_text $"Technical details" "$tmp"; rm -f -- "$tmp"
            ;;
         4) bsr_gui_remove "$dev"; return ;;
         5) bsr_load drive.sh && bsr_gui_drive_main health "${F[DISK]}"; return ;;
         *) return 0 ;;
      esac
   done
}

# Only the help text (notification action "How to solve")
bsr_gui_help() {
   bsr_resolve "${1:-}" && bsr_facts "$R_DEV" || return 1
   bsr_diagnose_write "$R_DEV" "$R_PATH"
   bsr_cause_key; bsr_cause_text "$REPLY"
   bsr_doc_new
   bsr_doc_h $"How to solve"
   bsr_doc_p "$C_REASON"
   local s; for s in "${C_HELP[@]}"; do bsr_doc_li "$s"; done
   bsr_ui_show info "$C_TITLE" help-about
}

# Apply the safe correction found by the diagnosis, after confirmation
bsr_gui_fix() {
   local dev="$1" fix="$D_FIX" mp="$D_MP" ok=0
   bsr_cause_text "$D_CAUSE"
   bsr_doc_new
   bsr_doc_h "$C_FIX_LABEL"
   bsr_doc_p "$C_FIX_INFO"
   bsr_ui_confirm "$C_FIX_LABEL" dialog-question "$C_FIX_LABEL" $"Cancel" || return 0
   case "$fix" in
      take-ownership)
         bsr_take_ownership "$dev"
         [ -w "$mp" ] && ok=1
         ;;
      remount)
         if ! bsr_drive_lock "${F[DISK]:-$dev}"; then
            bsr_notify info dialog-information "$C_FIX_LABEL" $"Another operation on this drive is in progress. Try again when it finishes."
            return 0
         fi
         if bsr_unmount_all "$dev"; then
            if bsr_udisks mount -b "$dev"; then
               bsr_diagnose_write "$dev"
               [ "$D_CAUSE" = ok ] && ok=1
            fi
         elif [[ $UD_ERROR == *DeviceBusy* ]]; then
            bsr_drive_unlock
            bsr_gui_busy_dialog "$dev"
            return 0
         fi
         bsr_drive_unlock
         ;;
   esac
   bsr_short_name
   if [ "$ok" -eq 1 ]; then
      bsr_notify info dialog-ok $"Device ready" "$REPLY"$'\n'$"You can now write to this device."
   else
      bsr_notify warning dialog-error $"Unable to fix the device" \
         "$REPLY"$'\n'$"Nothing was changed on the device. See the technical details for more information."
   fi
}

# ---------------------------------------------------------------------------
# Graphical safe removal (big-storage-rescue --gui-remove, Dolphin action)

# The processes of every user, read with administrator rights, are kept only
# while the busy dialog shows them: never left behind in /tmp
bsr_priv_clear() {
   [ -n "${BSR_PRIV_LSOF:-}" ] && rm -f -- "$BSR_PRIV_LSOF"
   BSR_PRIV_LSOF=""
}

# Busy dialog: returns 0 to try again, 1 to give up
bsr_gui_busy_dialog() {
   local dev="$1" priv="" tmp self
   bsr_priv_clear
   trap 'bsr_priv_clear; bsr_drive_unlock' EXIT
   trap 'bsr_priv_clear; bsr_drive_unlock; exit 130' INT TERM HUP
   while :; do
      bsr_busy_doc "$dev" "" "$priv"
      bsr_device_icon
      bsr_ui_choice $"Device is busy" dialog-warning $"Try again" $"More options…" $"Cancel"
      case "$REPLY" in
         1) bsr_priv_clear; return 0 ;;
         3) bsr_priv_clear; return 1 ;;
      esac
      local opts=(refresh $"Refresh the list" details $"Show technical details")
      bsr_close_candidates
      [ "${#CLOSE_PIDS[@]}" -gt 0 ] && opts+=(close $"Close the listed programs…")
      command -v pkexec >/dev/null && opts+=(admin $"Show programs of all users (administrator)")
      bsr_ui_menu $"Device is busy" $"What do you want to do?" "${opts[@]}"
      case "$REPLY" in
         details)
            tmp="$(mktemp)"; bsr_busy_details_file "$tmp" "$dev"
            bsr_ui_text $"Technical details" "$tmp"; rm -f -- "$tmp"
            ;;
         close)
            bsr_doc_new
            bsr_doc_h $"Close these programs?"
            local n; for n in "${CLOSE_NAMES[@]}"; do bsr_doc_li "$n"; done
            bsr_doc_p $"They will be asked to close, as when you close their windows. Unsaved changes in them may be lost: if possible, close them yourself instead."
            if [ "${#KEEP_NAMES[@]}" -gt 0 ]; then
               bsr_doc_p $"These will not be closed:"
               for n in "${!KEEP_NAMES[@]}"; do bsr_doc_li "${KEEP_NAMES[n]}: ${KEEP_WHY[n]}"; done
            fi
            if bsr_ui_confirm_risky $"Close programs" dialog-warning $"Close them" $"Cancel"; then
               bsr_close_args
               bsr_close_processes "${CLOSE_ARGS[@]}"
               return 0
            fi
            ;;
         admin)
            # Only this small helper runs as root (polkit action
            # org.biglinux.big-storage-rescue.inspect-processes); the dialogs stay
            # in the user session
            self="$BSR_LIB_DIR/bsr-holders"
            bsr_priv_clear
            tmp="$(mktemp)" || continue
            BSR_PRIV_LSOF="$tmp"
            bsr_mounts "$dev"
            local mp; for mp in "${M_TARGET[@]}"; do
               pkexec "$self" "$mp" >> "$tmp" 2>/dev/null
            done
            if [ -s "$tmp" ]; then priv=1; else bsr_priv_clear; priv=""; fi
            ;;
      esac
   done
}

# Shown when an unmount or power-off is still running after 2 seconds
# Once per removal, however many slow steps it has (unmount, release, power-off)
bsr_gui_slow_notice() {
   [ "${BSR_GUI_SLOW_SHOWN:-0}" = 1 ] && return 0
   BSR_GUI_SLOW_SHOWN=1
   bsr_notify info document-save "$BSR_GUI_NAME" $"Writing pending data to the device. Do not disconnect it yet." &
}

bsr_gui_remove() {
   local target="${1:-}" rc name short icon
   bsr_gui_target "$target" $"Safely remove" $"This folder is not on a removable storage device." || return 1
   local dev="$R_DEV"
   bsr_display_name; name="$REPLY"
   bsr_short_name; short="$REPLY"
   bsr_device_icon; icon="$REPLY"
   if ! bsr_drive_lock "${F[DISK]}"; then
      bsr_notify info "$icon" $"Safely remove" "$name"$'\n'$"The removal of this drive is already in progress." >/dev/null &
      return 10
   fi
   BSR_GUI_NAME="$short" BSR_SLOW_HOOK=bsr_gui_slow_notice BSR_GUI_SLOW_SHOWN=0 RM_ALLOW_SERVICES=0
   while :; do
      bsr_remove_core remove "$dev"; rc=$?
      case "$rc" in
         0)
            if [ "$RM_POWERED" = 1 ]; then
               bsr_notify info "$icon" $"Safe to disconnect" \
                  "$name"$'\n'$"Successfully unmounted and powered off. You can disconnect it now." >/dev/null &
            elif [ "$RM_REMOVABLE" = 1 ]; then
               bsr_notify info "$icon" $"Safe to disconnect" \
                  "$name"$'\n'$"Successfully unmounted. You can disconnect it now." >/dev/null &
            else
               bsr_notify info "$icon" $"Device unmounted" \
                  "$name"$'\n'$"All pending data was written and its filesystems were unmounted." >/dev/null &
            fi
            break
            ;;
         7)
            bsr_notify info "$icon" $"Safe to disconnect" \
               "$name"$'\n'$"Successfully unmounted. This drive cannot be powered off by the computer, but you can disconnect it now." >/dev/null &
            rc=0
            break
            ;;
         3) bsr_gui_busy_dialog "$RM_BUSY_DEV" || break ;;
         9)
            bsr_doc_new
            bsr_doc_h $"Services use this device"
            bsr_doc_p $"Removing it will stop these services:"
            local u; for u in "${!RM_DEP_UNITS[@]}"; do bsr_doc_li "${RM_DEP_NAMES[u]} (${RM_DEP_UNITS[u]})"; done
            bsr_dep_restart_text; bsr_doc_p "$REPLY"
            if bsr_ui_confirm_risky $"Services use this device" dialog-warning $"Stop them and remove" $"Cancel"; then
               RM_ALLOW_SERVICES=1
            else
               break
            fi
            ;;
         8)
            bsr_notify warning dialog-warning $"Unable to power off device" \
               "$name"$'\n'$"It was unmounted, but powering it off failed. Wait a moment before disconnecting it."$'\n'"$RM_REASON" >/dev/null &
            break
            ;;
         4)
            bsr_notify warning dialog-error $"Unable to remove device" \
               "$name"$'\n'$"It holds the operating system that is running now." >/dev/null &
            break
            ;;
         5)
            bsr_notify warning dialog-error $"Unable to unmount device" \
               "$name"$'\n'$"Permission was not granted. The device remains mounted." >/dev/null &
            break
            ;;
         6)
            bsr_notify warning dialog-warning $"Unable to power off device" \
               "$name"$'\n'$"Its filesystems were unmounted, but the drive is still in use, so it was not powered off. Do not disconnect it yet."$'\n'"$RM_REASON" >/dev/null &
            break
            ;;
         *)
            if [ "$RM_GONE" = 1 ]; then
               bsr_notify warning dialog-warning $"Device disconnected" \
                  "$name"$'\n'$"The device was disconnected before the removal finished. If files were being written to it, check them when you connect it again." >/dev/null &
            else
               bsr_notify warning dialog-error $"Unable to unmount device" \
                  "$name"$'\n'$"It remains mounted. Nothing was forced."$'\n'"${RM_REASON%%$'\n'*}" >/dev/null &
            fi
            break
            ;;
      esac
   done
   BSR_SLOW_HOOK=""
   bsr_drive_unlock
   return "$rc"
}

# ---------------------------------------------------------------------------
# Session notifier (big-storage-rescue --notifier). Off by default: the application turns
# it on by copying its entry to the person's XDG autostart folder
#
# Waits for mount events (findmnt --poll: the kernel wakes it up, there is no
# periodic scan) and warns once per boot and device when a removable or
# big-storage-rescue device cannot be written to. The GUI never runs as root: the
# boot service only leaves /run/big-mount/status for us to read.

bsr_notifier_key() {
   local boot=""
   read -r boot < /proc/sys/kernel/random/boot_id 2>/dev/null
   REPLY="$boot ${F[UUID]:-${1##*/}} $D_CAUSE"
}

# bsr_notifier_health DEV: a drive that reports problems gets a window, once per
# boot and drive (not per volume, not per reconnection), with the way to look
# at it. Only what the diagnosis reads anyway: the kernel log, udev and UDisks2,
# never the disk itself.
bsr_notifier_health() {
   local dev="$1" disk boot="" key name grade w
   [ "${F[DISK_TYPE]:-}" = disk ] || return 0
   disk="${F[DISK]}"
   declare -F bsr_ds_level >/dev/null || { bsr_load drive-detect.sh; bsr_load drive-diag.sh; }
   bsr_dv_scan 2>/dev/null || return 0
   [ -n "${DV[$disk|TYPE]:-}" ] || return 0
   bsr_ds_level "$disk"
   case "$DS_LEVEL" in critical | attention) ;; *) return 0 ;; esac
   # Errors of earlier starts were already there at the last login: the
   # application shows them, but they are not announced at every start
   for w in "${DS_WHY[@]}"; do
      case "$w" in past-errors | fs-errors) ;; *) w=""; break ;; esac
   done
   [ -z "$w" ] || return 0
   read -r boot < /proc/sys/kernel/random/boot_id 2>/dev/null
   bsr_dv_stable_id "$disk"; key="$boot health $REPLY"
   grep -qxF -- "$key" "$BSR_NOTIFIED" 2>/dev/null && return 0
   printf '%s\n' "$key" >> "$BSR_NOTIFIED"
   bsr_dv_name "$disk"; name="$REPLY"
   bsr_ds_grade_label; grade="$REPLY"
   bsr_doc_new
   printf -v REPLY $"%s: %s" "$name" "$grade"
   bsr_doc_h "$REPLY"
   if [ "$DS_LEVEL" = critical ]; then
      bsr_doc_p $"This drive reported serious problems. Copy your files to another drive before trying any repair."
   else
      bsr_doc_p $"This drive reported problems. Copy what matters to another place."
   fi
   for w in "${DS_WHY[@]}"; do bsr_ds_why_text "$w"; bsr_doc_li "$REPLY"; done
   bsr_doc_p $"Big Storage Rescue shows what was found and how to rescue the files without writing to the drive."
   (
      if bsr_ui_confirm $"A drive needs attention" dialog-warning $"Open Big Storage Rescue" $"Close"; then
         "$BSR_SELF" --gui-health "$disk"
      fi
   ) </dev/null >/dev/null 8>&- &
}

bsr_notifier_check() {
   local dev="$1" mp="$2" key cause body icon name l_details l_help acts=()
   [[ $dev == /dev/* ]] || return 0
   case "$mp" in
      /run/media/"${USER:-$BSR_USER}"/* | /media/* | /mnt/*) ;;
      *) return 0 ;;
   esac
   [ "$mp" = /mnt/user-mount ] && return 0
   bsr_facts "$dev" || return 0
   bsr_notifier_health "$dev"
   bsr_facts "$dev" || return 0
   # Optical discs and images are read-only by nature: nothing to explain
   [ "${F[DISK_TYPE]}" = rom ] && return 0
   case "${F[FSTYPE]}" in squashfs | iso9660 | erofs | udf) return 0 ;; esac
   bsr_diagnose_write "$dev"
   case "$D_CAUSE" in
      ok | not-mounted | unsupported) return 0 ;;
      # Read-only because the person asked for it in Big Storage Rescue
      hw-readonly | mounted-ro) bsr_chosen_ro "$dev" && return 0 ;;
   esac
   # Another operating system mounted by big-storage-rescue (its folders belong to it):
   # nothing to fix, so no warning at every login. --diagnose still explains it.
   bsr_cause_key
   [ "$REPLY" = permission-os ] && return 0
   bsr_notifier_key "$dev"; key="$REPLY"
   grep -qxF -- "$key" "$BSR_NOTIFIED" 2>/dev/null && return 0
   printf '%s\n' "$key" >> "$BSR_NOTIFIED"

   bsr_cause_key; cause="$REPLY"
   bsr_cause_text "$cause"
   bsr_display_name; name="$REPLY"
   bsr_fs_label "${F[FSTYPE]}"
   printf -v body $"Device: %s\nFilesystem: %s\nPossible reason: %s" "$name" "$REPLY" "$C_REASON"
   bsr_device_icon; icon="$REPLY"
   l_details=$"View details" l_help=$"How to solve"
   acts=("details=$l_details" "help=$l_help")
   # Offered only when a safe, verifiable correction exists for this cause
   [ -n "$D_FIX" ] && acts+=("fix=$C_FIX_LABEL")
   (
      action="$(bsr_notify warning "$icon" "$C_TITLE" "$body" "${acts[@]}")"
      case "$action" in
         details | fix) "$BSR_SELF" --gui-diagnose "$dev" ;;
         help) bsr_gui_help "$dev" ;;
      esac
   ) </dev/null >/dev/null 8>&- &
}

bsr_notifier() {
   local line rundir="${XDG_RUNTIME_DIR:-/run/user/$EUID}" statedir="${XDG_STATE_HOME:-$HOME/.local/state}/big-storage-rescue"
   BSR_USER="$(id -un)"
   BSR_SELF="$(readlink -f "$BSR_LIB_DIR/../../bin/big-storage-rescue")"
   [ -x /usr/bin/big-storage-rescue ] && [ "$BSR_LIB_DIR" = /usr/lib/big-storage-rescue ] && BSR_SELF=/usr/bin/big-storage-rescue
   mkdir -p -- "$statedir" || return 1
   BSR_NOTIFIED="$statedir/notified"
   # Forget other boots: the list only prevents repeating within one boot
   if [ -f "$BSR_NOTIFIED" ]; then
      local boot=""; read -r boot < /proc/sys/kernel/random/boot_id
      grep -F -- "$boot " "$BSR_NOTIFIED" > "$BSR_NOTIFIED.tmp" 2>/dev/null
      mv -f -- "$BSR_NOTIFIED.tmp" "$BSR_NOTIFIED"
   fi
   # One notifier per session. Children never get fd 8: one that outlived
   # the notifier would keep the lock, and every later notifier would quit.
   # Opened without truncating: the lock holds the PID of the notifier, which
   # the application stops when the person turns it off
   exec 8>> "$rundir/big-storage-rescue-notifier.lock" || return 1
   flock -n 8 || return 0
   printf '%s\n' "$$" > "$rundir/big-storage-rescue-notifier.lock"

   # Devices already mounted at login (big-storage-rescue mounts them at boot)
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      bsr_notifier_check "${KV[SOURCE]%%\[*}" "${KV[TARGET]}"
   done < <(findmnt -P -n -o SOURCE,TARGET 2>/dev/null 8>&-)

   # Then react to mounts and remounts (errors=remount-ro shows up as one)
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      case "${KV[ACTION]}" in
         mount | remount)
            bsr_notifier_check "${KV[SOURCE]%%\[*}" "${KV[TARGET]}"
            ;;
      esac
   # The kernel ends findmnt with the notifier (it would otherwise live on
   # until the next mount event, writing to a closed pipe)
   done < <(LC_ALL=C setpriv --pdeathsig TERM -- findmnt --poll=mount,remount -P -o ACTION,SOURCE,TARGET 2>/dev/null 8>&-)
}
