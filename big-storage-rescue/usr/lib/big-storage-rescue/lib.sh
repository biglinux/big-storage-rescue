# shellcheck shell=bash
# shellcheck disable=SC2034  # R_*, F, D_*, DH_*, H_*, O_*, UD_* are read by cli.sh
#
# Big Storage Rescue library: device facts, read-only diagnosis, what keeps a
# device busy, graceful closing of applications, safe removal and drive health.
#
# Sourced by /usr/bin/big-storage-rescue for every command. It runs as the
# logged-in user; what needs more goes through UDisks2, or through pkexec to
# bsr-holders (bsr_privileged_holders) and bsr-drive-helper.
#
# Conventions: helpers return values in REPLY or in global arrays to avoid
# forking a subshell per call; every external command gets its arguments as
# separate words, never through eval or a shell string.

export TEXTDOMAIN=big-storage-rescue
# /usr/lib/big-storage-rescue -> /usr/share/locale (a source checkout uses its own)
BSR_LIB_DIR="${BSR_LIB_DIR:-/usr/lib/big-storage-rescue}"
export TEXTDOMAINDIR="${BSR_LIB_DIR%/lib/big-storage-rescue}/share/locale"
# Translations are data: never let a .mo file expand $(...) or variables
shopt -s noexpand_translation 2>/dev/null

BSR_STATUS_FILE=/run/big-mount/status

# Mount points that belong to the running system: never unmounted by us
BSR_SYSTEM_MOUNTS=" / /boot /boot/efi /efi /home /usr /var /opt /srv /tmp /root /nix "

# Session processes that must not be closed even if they hold a file
BSR_PROTECTED_COMM=" systemd plasmashell kwin_wayland kwin_x11 kwin_wayland_wr ksmserver kded6 kded5 \
 startplasma-way startplasma-x11 plasma_session Xwayland Xorg dbus-daemon dbus-broker \
 dbus-broker-lau pipewire pipewire-pulse wireplumber sddm sddm-helper gnome-shell \
 gnome-session-b polkitd polkit-kde-aut xdg-desktop-por xdg-document-po kactivitymanage \
 udisksd bigmount big-storage-res sudo pkexec su login "

# Interactive shells ignore SIGTERM; the user has to leave the folder instead
BSR_SHELL_COMM=" bash zsh fish sh dash ksh mksh tcsh csh nu elvish xonsh "

bsr_warn() { printf 'big-storage-rescue: %s\n' "$*" >&2; }

# Pad or cut TEXT to WIDTH characters for terminal tables. printf counts
# bytes: "%-18.18s" misaligns accented labels and can cut one in the middle
# of a character. Control characters (from device data) become "?".
bsr_pad() {
   local s="${1//[[:cntrl:]]/?}" w="$2"
   [ "${#s}" -gt "$w" ] && s="${s:0:w-1}…"
   printf -v REPLY '%s%*s' "$s" $((w - ${#s})) ""
}

# Decode the \xHH escapes used by lsblk -P and findmnt -P
bsr_unescape() { printf -v REPLY '%b' "$1"; }

# Parse one KEY="value" line of lsblk/findmnt -P into the KV array
declare -gA KV
bsr_parse_pairs() {
   local rest="$1" re='^[[:space:]]*([A-Z0-9_:%-]+)="([^"]*)"(.*)$'
   KV=()
   while [[ $rest =~ $re ]]; do
      bsr_unescape "${BASH_REMATCH[2]}"
      KV[${BASH_REMATCH[1]}]="$REPLY"
      rest="${BASH_REMATCH[3]}"
   done
}

# Escape untrusted text (labels, file names, process names) for rich text.
# The replacements are quoted: since bash 5.2 an unquoted & in them stands
# for the matched text (patsub_replacement).
bsr_html() {
   local s="$1"
   s="${s//&/"&amp;"}"
   s="${s//</"&lt;"}"
   s="${s//>/"&gt;"}"
   s="${s//\"/"&quot;"}"
   REPLY="$s"
}

# Human readable size in powers of 1000, like Dolphin and the disk vendors
bsr_human_size() {
   local b="${1:-0}" units=(B kB MB GB TB PB) i=0 whole frac
   [[ $b =~ ^[0-9]+$ ]] || { REPLY="?"; return; }
   while [ "$b" -ge 1000000 ] && [ "$i" -lt 4 ]; do
      b=$((b / 1000)); i=$((i + 1))
   done
   if [ "$b" -ge 1000 ]; then
      whole=$((b / 1000)); frac=$(((b % 1000) / 100)); i=$((i + 1))
      if [ "$whole" -ge 100 ] || [ "$frac" -eq 0 ]; then REPLY="$whole ${units[i]}"; else REPLY="$whole.$frac ${units[i]}"; fi
   else
      REPLY="$b ${units[i]}"
   fi
}

# ---------------------------------------------------------------------------
# Device facts

# bsr_resolve TARGET: block device behind a /dev path, a mount point or any
# path inside a mounted filesystem. Sets R_DEV (e.g. /dev/sdd1), R_PATH (the
# path asked for, if any) and R_SUBVOL (btrfs subvolume, if any).
# Nothing is ever derived from the name: the kernel must know the device.
# On failure R_ERR says why (bsr_resolve_message explains it):
#   empty | missing (no such device or folder) | controller (an NVMe
#   controller such as /dev/nvme0, not its storage) | not-block (another
#   kind of file in /dev) | not-local (a folder on a network share, tmpfs...)
# Callers set unavailable when the node exists but the kernel has no device
# behind it any more (bsr_facts failed: unplugged, detached loop device).
bsr_resolve() {
   local target="$1" src
   R_DEV="" R_PATH="" R_SUBVOL="" R_ERR="" R_NODE=""
   if [ -z "$target" ]; then
      R_ERR=empty; return 1
   fi
   if [[ $target == /dev/* ]]; then
      src="$(readlink -f -- "$target")"
      R_NODE="$src"
      if [ -b "$src" ]; then
         R_DEV="$src"; return 0
      fi
      if [ ! -e "$src" ]; then R_ERR=missing
      elif [[ ${src##*/} =~ ^nvme[0-9]+$ ]] && [ -d "/sys/class/nvme/${src##*/}" ]; then R_ERR=controller
      else R_ERR=not-block
      fi
      return 1
   fi
   [ -e "$target" ] || { R_ERR=missing; return 1; }
   R_PATH="$target"
   src="$(findmnt -n -o SOURCE -T "$target" 2>/dev/null | head -n1)"
   if [[ $src == *\[*\] ]]; then
      R_SUBVOL="${src#*\[}"; R_SUBVOL="${R_SUBVOL%\]}"
      src="${src%%\[*}"
   fi
   if [[ $src != /dev/* ]] || [ ! -b "$src" ]; then
      R_ERR=not-local; return 2
   fi
   R_DEV="$(readlink -f -- "$src")"
}

# One translated sentence for the R_ERR of a failed bsr_resolve TARGET. For
# an NVMe controller the storage it holds is named (from sysfs, not guessed).
bsr_resolve_message() {
   local target="$1" ns=() n
   case "${R_ERR:-}" in
      empty) REPLY=$"No device or folder was given." ;;
      missing) printf -v REPLY $"'%s' does not exist. If it is a removable device, it may have been disconnected." "$target" ;;
      unavailable) printf -v REPLY $"'%s' is not available. If it is a removable device, it may have been disconnected." "$target" ;;
      controller)
         # Namespaces are block devices; hidden multipath paths (nvme0c0n1)
         # have no node in /dev
         for n in /sys/class/nvme/"${R_NODE##*/}"/nvme*n*; do
            [ -b "/dev/${n##*/}" ] && ns+=("/dev/${n##*/}")
         done
         printf -v REPLY $"'%s' is an NVMe controller, not a storage device. Its storage is: %s" "$target" "${ns[*]:-?}"
         ;;
      not-block) printf -v REPLY $"'%s' is not a storage device." "$target" ;;
      not-local) printf -v REPLY $"'%s' is not on a local storage device (it may be a network share or a memory filesystem)." "$target" ;;
      *) printf -v REPLY $"'%s' is not a local storage device or a folder on one" "$target" ;;
   esac
}

# For the terminal commands: the explanation on stderr, prefixed like every
# other message of big-storage-rescue
bsr_resolve_fail() {
   bsr_resolve_message "$1"
   printf 'big-storage-rescue: %s\n' "$REPLY" >&2
}

# bsr_facts DEV: fills the F array with what diagnosis and dialogs need.
# F[MOUNTS] holds the mount points separated by newlines.
declare -gA F
bsr_facts() {
   local dev="$1" line disk
   F=()
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      F[NAME]="${KV[NAME]:-}" F[KNAME]="${KV[KNAME]:-}" F[PKNAME]="${KV[PKNAME]:-}"
      F[TYPE]="${KV[TYPE]:-}" F[FSTYPE]="${KV[FSTYPE]:-}" F[FSVER]="${KV[FSVER]:-}"
      F[LABEL]="${KV[LABEL]:-}" F[UUID]="${KV[UUID]:-}" F[SIZE]="${KV[SIZE]:-}"
      F[RO]="${KV[RO]:-0}" F[MOUNTS]="${KV[MOUNTPOINTS]:-}"
      break
   done < <(lsblk -P -b -p -n -o NAME,KNAME,PKNAME,TYPE,FSTYPE,FSVER,LABEL,UUID,SIZE,RO,MOUNTPOINTS -- "$dev" 2>/dev/null)
   [ -n "${F[NAME]:-}" ] || return 1
   F[KNAME]="${F[KNAME]##*/}"

   # Walk up to the whole disk for model, transport and power-off
   disk="$dev"
   local pk="${F[PKNAME]}" n=0 kn slaves
   while [ "$n" -lt 8 ]; do
      # lsblk shows no parent for a device-mapper device (LUKS, LVM) asked
      # about directly: follow sysfs when there is exactly one
      if [ -z "$pk" ]; then
         kn="$(readlink -f -- "$disk")"
         slaves=(/sys/class/block/"${kn##*/}"/slaves/*)
         [ "${#slaves[@]}" -eq 1 ] && [ -e "${slaves[0]}" ] && pk="/dev/${slaves[0]##*/}"
      fi
      [ -n "$pk" ] || break
      disk="$pk"
      pk="$(lsblk -n -d -o PKNAME -- "$disk" 2>/dev/null)"
      [[ -n $pk && $pk != /dev/* ]] && pk="/dev/$pk"
      n=$((n + 1))
   done
   F[DISK]="$disk"
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      F[MODEL]="${KV[MODEL]:-}" F[VENDOR]="${KV[VENDOR]:-}" F[TRAN]="${KV[TRAN]:-}"
      F[DISK_RO]="${KV[RO]:-0}" F[HOTPLUG]="${KV[HOTPLUG]:-0}" F[RM]="${KV[RM]:-0}"
      F[DISK_TYPE]="${KV[TYPE]:-}" F[DISK_SIZE]="${KV[SIZE]:-}"
      break
   done < <(lsblk -P -b -p -n -d -o MODEL,VENDOR,TRAN,RO,HOTPLUG,RM,TYPE,SIZE -- "$disk" 2>/dev/null)
   F[MODEL]="${F[MODEL]%"${F[MODEL]##*[! ]}"}"
   F[VENDOR]="${F[VENDOR]%"${F[VENDOR]##*[! ]}"}"
   # SATA disks report the bus as vendor
   [ "${F[VENDOR]}" = ATA ] && F[VENDOR]=""
   return 0
}

# Friendly name: "Novo volume (SanDisk Portable SSD, 2 TB)"
bsr_display_name() {
   local name="${F[LABEL]:-}" what=""
   bsr_human_size "${F[SIZE]:-}"
   local size="$REPLY"
   [ -n "${F[VENDOR]:-}${F[MODEL]:-}" ] && what="${F[VENDOR]:+${F[VENDOR]} }${F[MODEL]:-}"
   [ -n "$name" ] || name="${F[NAME]##*/}"
   REPLY="$name (${what:+$what, }$size)"
}

# Short name for titles: the label, else vendor and model, else sdX1
bsr_short_name() {
   REPLY="${F[LABEL]:-}"
   [ -n "$REPLY" ] || REPLY="${F[VENDOR]:+${F[VENDOR]} }${F[MODEL]:-}"
   [ -n "$REPLY" ] || REPLY="${F[NAME]##*/}"
}

# The icon a file manager would show for this device
bsr_device_icon() {
   if [ "${F[DISK_TYPE]:-}" = rom ]; then REPLY=media-optical
   elif [ "${F[TRAN]:-}" = usb ] || [ "${F[HOTPLUG]:-0}" = 1 ] || [ "${F[RM]:-0}" = 1 ]; then REPLY=drive-removable-media
   else REPLY=drive-harddisk
   fi
}

# Drives that are meant to be unplugged (and powered off before that)
bsr_is_removable_drive() {
   [ "${F[TRAN]:-}" = usb ] || [ "${F[TRAN]:-}" = ieee1394 ] || [ "${F[HOTPLUG]:-0}" = 1 ] || [ "${F[RM]:-0}" = 1 ]
}

# bsr_mounts DEV: every mount of DEV (a device can be mounted more than once,
# e.g. a stale os-prober mount). Fills M_TARGET, M_FSTYPE, M_VFSOPT, M_FSOPT.
bsr_mounts() {
   local line
   M_TARGET=() M_FSTYPE=() M_VFSOPT=() M_FSOPT=()
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      M_TARGET+=("${KV[TARGET]}")
      M_FSTYPE+=("${KV[FSTYPE]}")
      M_VFSOPT+=("${KV[VFS-OPTIONS]}")
      M_FSOPT+=("${KV[FS-OPTIONS]}")
   done < <(findmnt -P -n -o TARGET,FSTYPE,VFS-OPTIONS,FS-OPTIONS --source "$1" 2>/dev/null)
}

bsr_has_opt() { [[ ",$1," == *",$2,"* ]]; }

# Value of an option such as uid=1000 in a comma separated list
bsr_opt_value() {
   local o
   REPLY=""
   IFS=, read -r -a _opts <<< "$1"
   for o in "${_opts[@]}"; do
      [[ $o == "$2="* ]] && { REPLY="${o#*=}"; return 0; }
   done
   return 1
}

# Line of /run/big-mount/status for DEV: "STATE REASON" in REPLY
bsr_boot_status() {
   local dev state reason
   REPLY=""
   [ -r "$BSR_STATUS_FILE" ] || return 1
   while IFS=$'\t' read -r dev _ _ state reason; do
      [ "$dev" = "$1" ] && { REPLY="$state $reason"; return 0; }
   done < "$BSR_STATUS_FILE"
   return 1
}

# Recent kernel messages about a device (journal of the current boot).
# Reading the journal may not be allowed; then nothing is reported.
bsr_kernel_messages() {
   local kname="$1" disk="$2"
   KMSG=()
   command -v journalctl >/dev/null || return 1
   mapfile -t KMSG < <(journalctl -k -b -q --no-pager -o cat -n 4000 \
      --grep "\\b(${kname}|${disk})\\b" 2>/dev/null | tail -n 60)
}

# Did ntfs-3g fall back to read-only for DEV? Its journal lines show the
# options that were asked for and the mode it actually used (same PID).
bsr_ntfs3g_fallback() {
   local dev="$1" line pid="" asked=""
   while IFS= read -r line; do
      [[ $line =~ \[([0-9]+)\]:\ (.*)$ ]] || continue
      case "${BASH_REMATCH[2]}" in
         "Mounted $dev (Read-Only"*) pid="${BASH_REMATCH[1]}" asked="" ;;
         "Cmdline options: "*)
            [ "${BASH_REMATCH[1]}" = "$pid" ] && asked="${BASH_REMATCH[2]#Cmdline options: }" ;;
      esac
   done < <(journalctl -b -q --no-pager -o short -n 400 -t ntfs-3g -t lowntfs-3g 2>/dev/null)
   [ -n "$pid" ] && ! bsr_has_opt "$asked" ro
}

bsr_kmsg_match() {
   local l
   for l in "${KMSG[@]}"; do
      [[ $l =~ $1 ]] && { REPLY="$l"; return 0; }
   done
   return 1
}

bsr_is_posix_fs() {
   case "$1" in
      ext2 | ext3 | ext4 | btrfs | xfs | f2fs | jfs | reiserfs | nilfs2 | bcachefs) return 0 ;;
   esac
   return 1
}

# A mounted filesystem that contains an operating system (another Linux
# install mounted by big-storage-rescue, a Windows C: drive): its root directory must
# keep its owner. The top level of a Btrfs install holds the system in
# subvolumes such as @, so one level below is checked as well.
bsr_looks_like_os() {
   local mp="$1" m
   for m in "$mp"/etc/os-release "$mp"/*/etc/os-release "$mp"/usr/bin "$mp"/*/usr/bin \
      "$mp"/boot/vmlinuz* "$mp"/*/boot/vmlinuz* "$mp"/Windows/System32 "$mp"/EFI/Microsoft \
      "$mp"/@ "$mp"/@home "$mp"/@rootfs "$mp"/timeshift-btrfs; do
      [ -e "$m" ] && return 0
   done
   return 1
}

# ---------------------------------------------------------------------------
# Read-only diagnosis

# bsr_diagnose_write DEV: why can't the current user write to DEV?
# Uses the F array (bsr_facts) and sets:
#   D_CAUSE  ok | not-mounted | hw-readonly | unsupported | ntfs-unsafe |
#            fs-errors | io-errors | mounted-ro | permission | permission-other-user
#   D_MP     mount point examined
#   D_DETAIL technical detail for "Details" (one line, untranslated facts)
#   D_FIX    safe automatic correction available: take-ownership | remount | ""
#   D_WARN   warnings that do not prevent writing (filesystem errors noticed)
bsr_diagnose_write() {
   local dev="$1" path="${2:-}" i ro=0 fstype mounted_type vfs fso st uid wt line
   D_CAUSE="" D_MP="" D_DETAIL="" D_FIX="" D_WARN=() D_OWNER="" D_PATH=""
   fstype="${F[FSTYPE]:-}"

   if [ "$fstype" = swap ]; then
      D_CAUSE=swap
      return 0
   fi

   bsr_mounts "$dev"
   if [ "${#M_TARGET[@]}" -eq 0 ]; then
      D_CAUSE=not-mounted
      if bsr_boot_status "$dev" && [[ $REPLY == failed* ]]; then
         D_DETAIL="big-storage-rescue: ${REPLY#failed }"
         [[ $REPLY == *ntfs-* ]] && D_CAUSE=ntfs-unsafe
      fi
      return 0
   fi

   # The first mount the user can see is the one that matters to them
   for i in "${!M_TARGET[@]}"; do
      [[ ${M_TARGET[i]} == /var/lib/os-prober/* ]] && continue
      D_MP="${M_TARGET[i]}" mounted_type="${M_FSTYPE[i]}" vfs="${M_VFSOPT[i]}" fso="${M_FSOPT[i]}"
      break
   done
   if [ -z "$D_MP" ]; then
      D_MP="${M_TARGET[0]}" mounted_type="${M_FSTYPE[0]}" vfs="${M_VFSOPT[0]}" fso="${M_FSOPT[0]}"
   fi
   # A folder was asked about ("why can't I write HERE?"): judge that folder,
   # under the mount that contains it, not the root of the partition
   wt="$D_MP"
   if [ -n "$path" ]; then
      [ -d "$path" ] || path="${path%/*}"
      while IFS= read -r line; do
         bsr_parse_pairs "$line"
         D_MP="${KV[TARGET]}" mounted_type="${KV[FSTYPE]}" vfs="${KV[VFS-OPTIONS]}" fso="${KV[FS-OPTIONS]}"
      done < <(findmnt -P -n -o TARGET,FSTYPE,VFS-OPTIONS,FS-OPTIONS -T "$path" 2>/dev/null)
      wt="$path"
      [ "$wt" = "$D_MP" ] || D_PATH="$wt"
   fi
   if bsr_has_opt "$vfs" ro || bsr_has_opt "$fso" ro; then ro=1; fi

   # Facts that are worth showing whatever the outcome
   local errcount=""
   if [ -r "/sys/fs/ext4/${F[KNAME]}/errors_count" ]; then
      read -r errcount < "/sys/fs/ext4/${F[KNAME]}/errors_count"
      [ "${errcount:-0}" -gt 0 ] && D_WARN+=("ext4 errors_count=$errcount")
   fi

   if [ "$ro" -eq 0 ] && [ -w "$wt" ]; then
      D_CAUSE=ok
      return 0
   fi

   # E: the device itself refuses writes (lock switch, write-protected media)
   if [ "${F[RO]:-0}" = 1 ] || [ "${F[DISK_RO]:-0}" = 1 ]; then
      D_CAUSE=hw-readonly
      D_DETAIL="/sys/block/${F[DISK]##*/}/ro=1"
      return 0
   fi

   if [ "$ro" -eq 1 ]; then
      # G: no write support in the filesystem or in the driver in use
      case "$mounted_type" in
         iso9660 | udf | squashfs | erofs | cramfs | romfs | apfs | hfs)
            D_CAUSE=unsupported; D_DETAIL="filesystem=$mounted_type"; return 0 ;;
         hfsplus)
            D_CAUSE=unsupported; D_DETAIL="hfsplus: journaled HFS+ is read-only on Linux"; return 0 ;;
         ntfs)
            # Kernel 6.9+ "ntfs" is the read-only legacy mode of ntfs3
            D_CAUSE=unsupported; D_DETAIL="driver=ntfs (read-only legacy driver)"; return 0 ;;
      esac

      bsr_kernel_messages "${F[KNAME]}" "${F[DISK]##*/}"

      # D: NTFS in a state that does not allow safe writes
      if [ "$fstype" = ntfs ]; then
         D_CAUSE=ntfs-unsafe
         if bsr_boot_status "$dev" && [[ $REPLY == *ntfs-* ]]; then
            D_DETAIL="big-storage-rescue: ${REPLY#* }"
         elif bsr_ntfs3g_fallback "$dev"; then
            D_DETAIL="ntfs-3g: read-write requested, mounted read-only by the driver"
         elif bsr_kmsg_match '[Hh]ibernat|[Ff]ast [Ss]tartup|unsafe state'; then
            D_DETAIL="ntfs-hibernated: $REPLY"
         elif bsr_kmsg_match 'volume is dirty|[Dd]irty|chkdsk'; then
            D_DETAIL="ntfs-dirty: $REPLY"
         elif bsr_kmsg_match 'unclean|not cleanly'; then
            D_DETAIL="ntfs-unclean: $REPLY"
         fi
         return 0
      fi

      # C: the kernel stopped writes after finding errors
      if bsr_kmsg_match 'remounting filesystem read-only|[Rr]emounting.*read-only|forced readonly|set read-only|[Ff]ilesystem has been shut down|EXT4-fs error|BTRFS (error|critical)|XFS.*(Corruption|metadata I/O error)|F2FS-fs.*(error|inconsistent)'; then
         D_CAUSE=fs-errors; D_DETAIL="$REPLY"; return 0
      fi
      if [ "${errcount:-0}" -gt 0 ]; then
         D_CAUSE=fs-errors; D_DETAIL="ext4 errors_count=$errcount"; return 0
      fi

      # F: the hardware reported I/O errors
      if bsr_kmsg_match 'I/O error|critical medium error|Buffer I/O error|reset.*USB|device descriptor read'; then
         D_CAUSE=io-errors; D_DETAIL="$REPLY"; return 0
      fi

      # A: mounted read-only on purpose (or by a mount option)
      D_CAUSE=mounted-ro
      D_DETAIL="options=$vfs"
      # Remounting is offered only for UDisks mounts, never for fstab entries
      if [[ $D_MP == /run/media/* || $D_MP == /media/* ]] && ! findmnt --fstab --source "$dev" >/dev/null 2>&1; then
         D_FIX=remount
      fi
      return 0
   fi

   # B: mounted read-write, but the current user has no permission
   if [ -n "$D_PATH" ]; then
      # A folder of someone else inside a writable filesystem: explain, never
      # offer to change owners below the root of a filesystem
      st="$(stat -c '%U:%G %a' -- "$wt" 2>/dev/null)"
      D_CAUSE=permission-folder D_OWNER="${st%%:*}"
      D_DETAIL="folder $wt $st"
   elif bsr_is_system_mount "$D_MP"; then
      # Part of the running system (/, /boot/efi, ...): not for users to write
      st="$(stat -c '%U:%G %a' -- "$D_MP" 2>/dev/null)"
      D_CAUSE=system
      D_DETAIL="system mount $D_MP $st"
   elif bsr_is_posix_fs "$fstype"; then
      st="$(stat -c '%U:%G %a' -- "$D_MP" 2>/dev/null)"
      D_CAUSE=permission
      D_DETAIL="root directory $st"
      if ! bsr_looks_like_os "$D_MP" && [[ $D_MP != /var/lib/os-prober/* ]]; then
         D_FIX=take-ownership
      fi
   else
      D_CAUSE=permission-other-user
      bsr_opt_value "$vfs,$fso" uid && uid="$REPLY"
      D_DETAIL="uid=${uid:-?} (you are $EUID)"
      if [[ $D_MP == /run/media/* ]]; then
         D_FIX=remount
      fi
   fi
}

# ---------------------------------------------------------------------------
# What keeps a filesystem busy

# Friendly application name for a process (translated)
bsr_app_name() {
   local comm="$1" proto="$2"
   case "$comm" in
      dolphin) REPLY=$"Dolphin (file manager)" ;;
      kioworker | kioworker6 | kioslave5 | kioslave)
         case "$proto" in
            thumbnail) REPLY=$"KDE thumbnail generator" ;;
            trash) REPLY=$"KDE trash" ;;
            file | "") REPLY=$"KDE file service (kioworker)" ;;
            *) printf -v REPLY $"KDE file service (%s)" "$proto" ;;
         esac
         ;;
      baloo_file | baloo_file_extr | baloorunner) REPLY=$"Baloo file indexer" ;;
      tracker-miner-f | tracker-extract | localsearch*) REPLY=$"File indexer (Tracker)" ;;
      konsole | yakuake | kitty | alacritty | foot | wezterm-gui | xterm | gnome-terminal- | kgx | tilix | terminator | ptyxis*)
         REPLY=$"Terminal" ;;
      bash | zsh | fish | sh | dash | ksh | mksh | tcsh | csh | nu | elvish | xonsh)
         REPLY=$"Command shell (terminal)" ;;
      vlc | mpv | haruna | elisa | smplayer | celluloid | totem | audacious | clementine | strawberry | rhythmbox | kaffeine | dragon)
         REPLY=$"Media player" ;;
      ffmpegthumbnail | *thumbnailer*) REPLY=$"Thumbnail generator" ;;
      okular | evince | papers) REPLY=$"Document viewer" ;;
      gwenview | eog | loupe | digikam | shotwell) REPLY=$"Image viewer" ;;
      kate | kwrite | gedit | gnome-text-edit | code | codium | mousepad) REPLY=$"Text editor" ;;
      soffice.bin | libreoffice*) REPLY="LibreOffice" ;;
      firefox | firefox-bin | chromium | chrome | brave | vivaldi-bin | opera | msedge) REPLY=$"Web browser" ;;
      nautilus | nemo | thunar | pcmanfm* | caja | krusader | doublecmd) REPLY=$"File manager" ;;
      cp | mv | rsync | tar | dd | 7z | 7za | unzip | unrar | zip | ark | file-roller | pv)
         REPLY=$"Copy or archive operation" ;;
      syncthing | nextcloud | dropbox | megasync | rclone | insync | owncloud) REPLY=$"Synchronization service" ;;
      borg | restic | deja-dup | duplicity | timeshift* | kup-daemon | vorta) REPLY=$"Backup" ;;
      steam | steamwebhelper) REPLY="Steam" ;;
      *) REPLY="$comm" ;;
   esac
}

# How a process uses the filesystem (from lsof's FD and access fields)
bsr_access_label() {
   local fd="$1" acc="$2" type="$3"
   case "$fd" in
      cwd) REPLY=$"Current folder is on the device" ;;
      rtd) REPLY=$"Root folder (chroot) is on the device" ;;
      txt) REPLY=$"Program running from the device" ;;
      mem) REPLY=$"File mapped in memory" ;;
      *)
         case "$acc" in
            w) REPLY=$"Open for writing" ;;
            u) REPLY=$"Open for reading and writing" ;;
            *) if [ "$type" = DIR ]; then REPLY=$"Folder open"; else REPLY=$"Open for reading"; fi ;;
         esac
         ;;
   esac
}

bsr_proc_state() {
   local stat rest
   REPLY="" PROC_START=""
   # The process may end at any moment: that is not an error
   { read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 1
   rest="${stat##*) }"
   # shellcheck disable=SC2086
   set -- $rest
   REPLY="$1"
   PROC_START="${20:-}"
}

# bsr_holders MOUNTPOINT [LSOF_OUTPUT_FILE]: processes using the filesystem
# mounted on MOUNTPOINT, from `lsof -F` (structured field output). As a
# normal user only the user's own processes are visible.
# Fills H_PID H_UID H_USER H_COMM H_APP H_FD H_ACCESS H_PATH H_STATE H_START
# (one entry per open file) and H_PIDS (unique pids, in order).
bsr_holders() {
   local mp="$1" src="${2:-}" line pid="" uid="" user="" comm="" fd="" acc="" type="" name
   local -A seen=()
   H_PID=() H_UID=() H_USER=() H_COMM=() H_APP=() H_FD=() H_ACCESS=() H_PATH=() H_STATE=() H_START=() H_PIDS=() H_ARGS=()

   _bsr_holder_flush() {
      [ -n "$pid" ] && [ -n "$fd" ] || return 0
      local proto="" args=()
      if [ -r "/proc/$pid/cmdline" ]; then
         mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null
         # kioworker <plugin path> <protocol> ...
         [[ $comm == kioworker* || $comm == kioslave* ]] && proto="${args[2]:-}"
      fi
      bsr_app_name "$comm" "$proto"; H_APP+=("$REPLY")
      H_PID+=("$pid") H_UID+=("$uid") H_USER+=("$user") H_COMM+=("$comm")
      H_FD+=("$fd") H_ACCESS+=("$acc") H_PATH+=("$name")
      bsr_proc_state "$pid"; H_STATE+=("$REPLY") H_START+=("$PROC_START")
      H_ARGS+=("${args[*]:0:4}")
      if [ -z "${seen[$pid]:-}" ]; then seen[$pid]=1; H_PIDS+=("$pid"); fi
      fd=""
   }

   while IFS= read -r line; do
      case "${line:0:1}" in
         p) _bsr_holder_flush; pid="${line:1}" uid="" user="" comm="" ;;
         u) uid="${line:1}" ;;
         L) user="${line:1}" ;;
         c) comm="${line:1}" ;;
         f) _bsr_holder_flush; fd="${line:1}" acc="" type="" name="" ;;
         a) acc="${line:1}"; acc="${acc// /}" ;;
         t) type="${line:1}" ;;
         n) name="${line:1}" ;;
      esac
   done < <(if [ -n "$src" ]; then cat -- "$src"; else lsof -w -F pcuLftan -- "$mp" 2>/dev/null; fi)
   _bsr_holder_flush
   unset -f _bsr_holder_flush
}

# Kernel-level users of a filesystem or block device that no process list
# shows: other mounts of the device, filesystems mounted inside, swap files,
# loop devices backed by files on it, device-mapper/RAID holders.
# Fills O_KIND and O_WHAT (parallel arrays).
bsr_other_holders() {
   local dev="$1" kname="${1##*/}" mp t f back swapf h
   O_KIND=() O_WHAT=()
   bsr_mounts "$dev"
   local targets=("${M_TARGET[@]}")
   if [ "${#targets[@]}" -gt 1 ]; then
      for t in "${targets[@]}"; do O_KIND+=(mount) O_WHAT+=("$t"); done
   fi
   for mp in "${targets[@]}"; do
      while IFS= read -r t; do
         bsr_unescape "$t"; t="$REPLY"
         [ "$t" = "$mp" ] && continue
         O_KIND+=(nested) O_WHAT+=("$t")
      done < <(findmnt -n -r -o TARGET -R -- "$mp" 2>/dev/null | tail -n +2)
      while read -r swapf _; do
         [[ $swapf == "$mp"/* ]] && O_KIND+=(swapfile) O_WHAT+=("$swapf")
      done < /proc/swaps
      for f in /sys/block/loop*/loop/backing_file; do
         [ -r "$f" ] || continue
         read -r back < "$f"
         if [[ $back == "$mp"/* ]]; then
            f="${f%/loop/backing_file}"
            O_KIND+=(loop) O_WHAT+=("/dev/${f##*/} → $back")
         fi
      done
   done
   while read -r swapf _; do
      [ "$swapf" = "$dev" ] && O_KIND+=(swap) O_WHAT+=("$dev")
   done < /proc/swaps
   for h in "/sys/class/block/$kname/holders/"*; do
      [ -e "$h" ] || continue
      O_KIND+=(holder) O_WHAT+=("/dev/${h##*/}")
   done
   bsr_private_mounts "$dev"
   for h in "${!P_PIDS[@]}"; do
      O_KIND+=(isolated) O_WHAT+=("${P_COMMS[h]} (PID ${P_PIDS[h]}): ${P_MPS[h]}")
   done
}

# Can the user be offered to close this process? Sets REPLY to "" when yes,
# otherwise to the reason (translated).
bsr_close_refusal() {
   local idx="$1" pid="${H_PID[$1]}" comm="${H_COMM[$1]}" j
   if [ "${H_UID[idx]}" != "$EUID" ]; then
      REPLY=$"belongs to another user or to the system"; return 1
   fi
   if [[ $BSR_PROTECTED_COMM == *" $comm "* ]]; then
      REPLY=$"part of the desktop session"; return 1
   fi
   if [[ $BSR_SHELL_COMM == *" $comm "* ]]; then
      REPLY=$"a terminal: type 'cd' in it or close the tab"; return 1
   fi
   if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then
      REPLY=$"this tool"; return 1
   fi
   # Closing a program that is writing would leave an incomplete file
   for j in "${!H_PID[@]}"; do
      if [ "${H_PID[j]}" = "$pid" ] && { [ "${H_ACCESS[j]}" = w ] || [ "${H_ACCESS[j]}" = u ]; }; then
         REPLY=$"has a file open for writing: finish or cancel the operation in the application"; return 1
      fi
   done
   REPLY=""
   return 0
}

# bsr_close_processes PID START...: ask the given processes to exit (SIGTERM,
# never SIGKILL) after checking they are still the same processes. Waits up
# to 5 seconds. Sets CLOSE_LEFT to the pids still running.
bsr_close_processes() {
   local pid start uid asked=() n
   CLOSE_LEFT=()
   while [ "$#" -ge 2 ]; do
      pid="$1" start="$2"; shift 2
      if ! [[ $pid =~ ^[0-9]+$ ]] || [ "$pid" -le 1 ]; then continue; fi
      bsr_proc_state "$pid" || continue
      # The pid may have been reused by an unrelated process meanwhile
      [ "$PROC_START" = "$start" ] || continue
      uid="$(stat -c %u "/proc/$pid" 2>/dev/null)"
      [ "$uid" = "$EUID" ] || continue
      kill -TERM -- "$pid" 2>/dev/null && asked+=("$pid")
   done
   for ((n = 0; n < 25; n++)); do
      CLOSE_LEFT=()
      for pid in "${asked[@]}"; do
         kill -0 "$pid" 2>/dev/null && CLOSE_LEFT+=("$pid")
      done
      [ "${#CLOSE_LEFT[@]}" -eq 0 ] && return 0
      sleep 0.2
   done
   return 1
}

# ---------------------------------------------------------------------------
# Unmount and power off through UDisks2 (polkit decides about passwords)

# bsr_udisks CMD...: run udisksctl, keeping the D-Bus error name in UD_ERROR.
# When BSR_SLOW_HOOK names a function, it is called once if the operation is
# still running after 2 seconds (an unmount waits for pending writes): the
# GUI uses it to say "do not disconnect yet". No polling: wait -n returns
# when the first of the two finishes.
bsr_udisks() {
   local out rc
   if [ -n "${BSR_SLOW_HOOK:-}" ]; then
      local tmp pid timer
      tmp="$(mktemp)" || return 1
      udisksctl "$@" > "$tmp" 2>&1 &
      pid=$!
      sleep 2 &
      timer=$!
      wait -n "$pid" "$timer"
      if kill -0 "$pid" 2>/dev/null; then "$BSR_SLOW_HOOK" "$@"; fi
      kill "$timer" 2>/dev/null
      wait "$timer" 2>/dev/null
      wait "$pid"
      rc=$?
      out="$(< "$tmp")"
      rm -f -- "$tmp"
   else
      out="$(udisksctl "$@" 2>&1)"
      rc=$?
   fi
   UD_ERROR="" UD_MESSAGE="$out"
   if [ "$rc" -ne 0 ]; then
      if [[ $out =~ GDBus\.Error:([A-Za-z0-9_.]+) ]]; then
         UD_ERROR="${BASH_REMATCH[1]}"
      elif [[ $out == *"Error looking up object for device"* ]]; then
         # udisksctl's own message (no D-Bus error): UDisks2 has no object
         # for this name, so the device is gone or was never a block device
         UD_ERROR=no-object
      else
         UD_ERROR=unknown
      fi
   fi
   return "$rc"
}

# bsr_udisks_object DEV: the UDisks2 object of a block device, as UDisks2
# itself names it (REPLY), never built from the device name. Fails when
# UDisks2 does not know the device (disconnected, or not a block device).
bsr_udisks_object() {
   local line
   REPLY=""
   line="$(LC_ALL=C udisksctl info -b "$1" 2>/dev/null | head -n1)"
   [[ $line =~ ^(/org/freedesktop/UDisks2/block_devices/[A-Za-z0-9_]+):$ ]] || return 1
   REPLY="${BASH_REMATCH[1]}"
}

# bsr_is_system_mount MOUNTPOINT
bsr_is_system_mount() { [[ $BSR_SYSTEM_MOUNTS == *" $1 "* ]]; }

# bsr_drive_members DISK: block devices of a drive (the disk, its partitions
# and anything stacked on them), in lsblk order. Fills DRIVE_DEVS and
# DRIVE_FSTYPES.
bsr_drive_members() {
   local line
   DRIVE_DEVS=() DRIVE_FSTYPES=()
   while IFS= read -r line; do
      bsr_parse_pairs "$line"
      DRIVE_DEVS+=("${KV[NAME]}") DRIVE_FSTYPES+=("${KV[FSTYPE]}")
   done < <(lsblk -P -n -p -o NAME,FSTYPE -- "$1" 2>/dev/null)
}

# Is something (dm-crypt, LVM, md) stacked on this block device?
bsr_has_holders() { compgen -G "/sys/class/block/${1##*/}/holders/*" >/dev/null; }

# Sequence number of a disk: it changes when another device takes the name
bsr_diskseq() {
   REPLY=""
   { read -r REPLY < "/sys/block/${1##*/}/diskseq"; } 2>/dev/null
}

# bsr_seq_of DEV: the disk sequence number of the one disk DEV sits on, for
# the helper to check right before it acts (BSR_SEQ: empty, or one word)
bsr_seq_of() {
   local name type disks=()
   BSR_SEQ=()
   while read -r name type; do
      [ "$type" = disk ] && disks+=("$name")
   done < <(lsblk -s -n -p -r -o NAME,TYPE -- "$1" 2>/dev/null)
   [ "${#disks[@]}" -eq 1 ] || return 0
   bsr_diskseq "${disks[0]}"
   [[ $REPLY =~ ^[0-9]+$ ]] && BSR_SEQ=("$REPLY")
   return 0
}

# Read-only by choice: a read-only mount, or writing blocked on a drive, that
# the person asked Big Storage Rescue for is not reported back to them as a problem.
# Recorded in the private runtime folder with the disk sequence number, which
# changes when another device takes the name. bsr_chosen_ro_add DEV DISK;
# bsr_chosen_ro DEV after bsr_facts.
bsr_chosen_ro_add() {
   local dir="${XDG_RUNTIME_DIR:-}"
   { [ -n "$dir" ] && [ -d "$dir" ] && [ -O "$dir" ]; } || return 0
   bsr_diskseq "$2"
   [ -n "$REPLY" ] && printf '%s %s\n' "$REPLY" "$1" >> "$dir/big-storage-rescue-read-only"
}

bsr_chosen_ro() {
   local file="${XDG_RUNTIME_DIR:-}/big-storage-rescue-read-only"
   [ -r "$file" ] || return 1
   bsr_diskseq "${F[DISK]:-}"
   [ -n "$REPLY" ] && grep -qxF -e "$REPLY $1" -e "$REPLY ${F[DISK]}" -- "$file"
}

# bsr_drive_lock DISK: one removal or remount of a drive at a time. A double
# click on the Dolphin action, or the action and a terminal command, must
# not unmount and power off the same drive concurrently. The lock file is
# in the private runtime folder of the user, where nobody else can plant a
# symlink. Returns 1 when another operation holds it. bsr_drive_unlock
# releases it even if a child process (a notification) inherited the fd.
bsr_drive_lock() {
   local dir="${XDG_RUNTIME_DIR:-/run/user/$EUID}"
   BSR_LOCK_FD=""
   # Without a private folder (an unusual environment) there is no lock
   { [ -d "$dir" ] && [ -O "$dir" ]; } || return 0
   { exec {BSR_LOCK_FD}>"$dir/big-storage-rescue-drive-${1##*/}.lock"; } 2>/dev/null || { BSR_LOCK_FD=""; return 0; }
   flock -n "$BSR_LOCK_FD" && return 0
   exec {BSR_LOCK_FD}>&-
   BSR_LOCK_FD=""
   return 1
}

bsr_drive_unlock() {
   [ -n "${BSR_LOCK_FD:-}" ] || return 0
   flock -u "$BSR_LOCK_FD" 2>/dev/null
   exec {BSR_LOCK_FD}>&-
   BSR_LOCK_FD=""
}

# bsr_system_use DISK: non-empty REPLY when the drive holds the running
# system (a system mount point or active swap).
bsr_system_use() {
   local d t sw
   REPLY=""
   bsr_drive_members "$1"
   for d in "${DRIVE_DEVS[@]}"; do
      bsr_mounts "$d"
      for t in "${M_TARGET[@]}"; do
         if bsr_is_system_mount "$t"; then REPLY="$d → $t"; return 0; fi
      done
      while read -r sw _; do
         [ "$sw" = "$d" ] && { REPLY="$d → swap"; return 0; }
      done < /proc/swaps
   done
   return 1
}

# bsr_path_disks PATH: the whole disks that store the filesystem PATH is on,
# in BK_DISKS: through partitions, LUKS, LVM and RAID, every device of a
# Btrfs, and from a loop device on to the disks of the file behind it. 0 when
# that is known (BK_DISKS stays empty for memory, or a share of another
# computer); 1 when it cannot be told, as for FUSE without a device, an
# overlay or a share served by this computer: what must never be written on
# a drive refuses those.
bsr_path_disks() {
   BK_DISKS=()
   _bsr_path_disks "$1" 0
}

_bsr_path_disks() {
   local out src fstype host uuid m
   [ "$2" -lt 8 ] || return 1
   out="$(timeout 10 findmnt -n -P -o SOURCE,FSTYPE -T "$1" 2>/dev/null)" && [ -n "$out" ] || return 1
   bsr_parse_pairs "${out%%$'\n'*}"
   src="${KV[SOURCE]%%\[*}" fstype="${KV[FSTYPE]}"
   case "$fstype" in
      tmpfs | ramfs) return 0 ;;
      nfs | nfs4 | cifs | smb3)
         # //host/share or host:/path; a share of this computer can be on any of its disks
         if [[ $src == //* ]]; then host="${src#//}"; host="${host%%/*}"; else host="${src%%:/*}"; fi
         host="${host#[}"; host="${host%]}"
         bsr_share_is_remote "$host"
         return
         ;;
   esac
   [[ $src == /dev/* ]] || return 1
   _bsr_dev_disks "$src" "$2" || return 1
   # findmnt names one device of a Btrfs that may span several
   if [ "$fstype" = btrfs ]; then
      uuid="$(lsblk -n -d -o UUID -- "$src" 2>/dev/null)"
      [ -n "$uuid" ] || return 1
      for m in "/sys/fs/btrfs/$uuid/devices/"*; do
         [ -e "$m" ] || continue
         _bsr_dev_disks "/dev/${m##*/}" "$2" || return 1
      done
   fi
   return 0
}

# bsr_share_is_remote HOST: a share is served by another computer. Every
# address the name has is compared with the addresses of this one (a share
# through 192.168.1.10 can be served from here); a name that does not
# resolve, or addresses that cannot be read, count as this computer
BSR_SHARE_HOST_PY='
import ipaddress, socket, sys
mine, a = set(), None
try:
    for line in open("/proc/net/fib_trie"):
        f = line.split()
        if f[:1] == ["|--"]: a = f[1]
        elif "/32 host LOCAL" in line and a: mine.add(ipaddress.ip_address(a))
except (OSError, ValueError):
    sys.exit(1)
try:
    for line in open("/proc/net/if_inet6"):
        h = line.split()[0]
        mine.add(ipaddress.ip_address(":".join(h[i:i + 4] for i in range(0, 32, 4))))
except FileNotFoundError:
    pass  # IPv6 turned off: no address of this computer is missing
except (OSError, ValueError):
    sys.exit(1)
try:
    found = {ipaddress.ip_address(i[4][0].split("%")[0]) for i in socket.getaddrinfo(sys.argv[1], None)}
except (OSError, ValueError, UnicodeError):
    sys.exit(1)
def here(x):
    return x.is_loopback or x.is_unspecified or x in mine or (x.version == 6 and x.ipv4_mapped in mine)
sys.exit(0 if found and not any(here(x) for x in found) else 1)
'
bsr_share_is_remote() {
   local mine
   [ -n "$1" ] || return 1
   { read -r mine < /proc/sys/kernel/hostname; } 2>/dev/null
   [ "${1,,}" != "${mine,,}" ] || return 1
   timeout 10 python3 -I -c "$BSR_SHARE_HOST_PY" "$1" 2>/dev/null
}

_bsr_dev_disks() {
   local name type backing found=0
   while read -r name type; do
      found=1
      case "$type" in
         disk) BK_DISKS+=("$name") ;;
         loop)
            BK_DISKS+=("$name")
            backing="$(cat "/sys/block/${name##*/}/loop/backing_file" 2>/dev/null)"
            [ -n "$backing" ] && _bsr_path_disks "$backing" "$(($2 + 1))" || return 1
            ;;
      esac
   done < <(lsblk -s -n -p -r -o NAME,TYPE -- "$1" 2>/dev/null)
   [ "$found" = 1 ]
}

# FUSE daemons serving DEV (ntfs-3g, lowntfs-3g, exfat-fuse...): umount
# returns as soon as the kernel detaches the mount, but the daemon then
# still writes the final metadata to the device. Fills FUSE_PIDS.
# /proc/PID/cmdline is readable for every user, so root daemons are seen.
# /proc/PID/comm keeps 15 characters: mount.lowntfs-3g is "mount.lowntfs-3"
BSR_FUSE_COMM=" mount.ntfs-3g ntfs-3g mount.lowntfs-3 lowntfs-3g mount.ntfs mount.exfat-fus exfat-fuse mount.exfat mount.fuseblk "
bsr_fuse_daemons() {
   local dev="$1" d comm args
   FUSE_PIDS=()
   for d in /proc/[0-9]*; do
      { read -r comm < "$d/comm"; } 2>/dev/null || continue
      [[ $BSR_FUSE_COMM == *" $comm "* ]] || continue
      { mapfile -d '' -t args < "$d/cmdline"; } 2>/dev/null || continue
      [[ " ${args[*]} " == *" $dev "* ]] && FUSE_PIDS+=("${d#/proc/}")
   done
}

# Mounts of DEV that an unmount here does not remove: copies in other mount
# namespaces (a container, a sandboxed service) that do not receive our
# mount events. The kernel keeps the filesystem alive while one exists.
# A copy that does receive them carries shared:G or master:G of a peer
# group G of our own mount. A plain copy of our mount (same folder of the
# filesystem at the same place) goes away with it; a bind mount made inside
# the namespace, as Docker does for a volume, does not (measured on 7.2).
# Fills P_PIDS, P_COMMS and P_MPS (one per mount).
bsr_private_mounts() {
   local dev="$1" mm line file pid rest f i src comm skip='^$'
   local -a fields
   local -A seen=() ours=()
   P_PIDS=() P_COMMS=() P_MPS=()
   mm="$(lsblk -dnro MAJ:MIN -- "$dev" 2>/dev/null)"
   [ -n "$mm" ] || return 0
   _bsr_mi_fields() {
      read -r -a fields <<< "$1"
      src=""
      for ((i = 6; i < ${#fields[@]}; i++)); do
         [ "${fields[i]}" = - ] && { src="${fields[i + 2]:-}"; break; }
      done
   }
   while IFS= read -r line; do
      _bsr_mi_fields "$line"
      [ "${fields[2]}" = "$mm" ] || [ "$src" = "$dev" ] || continue
      ours["${fields[3]} ${fields[4]}"]=1
      for f in "${fields[@]:6}"; do
         [ "$f" = - ] && break
         [[ $f == shared:* ]] && skip+="| (shared|master):${f#shared:} "
      done
   done < /proc/self/mountinfo
   # The copies that follow ours are dropped by grep: hundreds of processes
   # share them, and parsing them here would cost tens of milliseconds
   while IFS= read -r line; do
      file="${line%%:*}" rest="${line#*:}"
      pid="${file#/proc/}" pid="${pid%%/*}"
      _bsr_mi_fields "$rest"
      [ "${fields[2]:-}" = "$mm" ] || [ "$src" = "$dev" ] || continue
      [ -n "${seen[${fields[0]}]:-}" ] && continue
      seen[${fields[0]}]=1
      [ -n "${ours["${fields[3]} ${fields[4]}"]:-}" ] && continue
      { read -r comm < "/proc/$pid/comm"; } 2>/dev/null || comm="?"
      bsr_unescape "${fields[4]}"
      P_PIDS+=("$pid") P_COMMS+=("$comm") P_MPS+=("$REPLY")
   done < <(grep -H -s -F -e " $mm " -e " $dev " /proc/[0-9]*/mountinfo | grep -v -E -- "$skip")
}

# After an unmount here, wait until the filesystem is really released: every
# FUSE daemon given has exited (it writes its cache after umount returns) and
# no private copy of the mount is left (a service that systemd stops with the
# mount, a container). At most BSR_FUSE_WAIT seconds; there is no event for
# the exit of a process that is not our child, so this checks every 0.1 s.
# On failure UD_ERROR is mounted-elsewhere or still-writing.
BSR_FUSE_WAIT=60
bsr_wait_released() {
   local dev="$1" pid n left
   shift
   for ((n = 0; n <= BSR_FUSE_WAIT * 10; n++)); do
      # Same "do not disconnect yet" notice as a slow unmount, after 2 s
      [ "$n" -eq 20 ] && [ -n "${BSR_SLOW_HOOK:-}" ] && "$BSR_SLOW_HOOK"
      left=0
      if [ $((n % 10)) -eq 0 ]; then
         bsr_private_mounts "$dev"
         [ "${#P_PIDS[@]}" -gt 0 ] && left=1
      fi
      for pid in "$@"; do
         if kill -0 "$pid" 2>/dev/null || [ -d "/proc/$pid" ]; then left=1; fi
      done
      [ "$left" -eq 0 ] && return 0
      [ "$n" -lt $((BSR_FUSE_WAIT * 10)) ] && sleep 0.1
   done
   if [ "${#P_PIDS[@]}" -gt 0 ]; then
      UD_ERROR=mounted-elsewhere
      printf -v UD_MESSAGE $"%s is unmounted here, but %s (PID %s) still has it mounted at %s" \
         "$dev" "${P_COMMS[0]}" "${P_PIDS[0]}" "${P_MPS[0]}"
   else
      UD_ERROR=still-writing
      printf -v UD_MESSAGE $"%s is unmounted, but its filesystem driver is still writing to it" "$dev"
   fi
   return 1
}

# bsr_unmount_all DEV: unmount every mount of one filesystem. Returns 0 when
# none is left and every FUSE daemon of the device has finished writing,
# 1 on failure (UD_ERROR/UD_MESSAGE describe it). The mount table is the
# judge, not the answer of udisksctl: a mount that vanished in the meantime
# is a success, a "success" that left the mount is a failure.
bsr_unmount_all() {
   local dev="$1" n daemons=()
   bsr_fuse_daemons "$dev"
   daemons=("${FUSE_PIDS[@]}")
   for ((n = 0; n < 8; n++)); do
      bsr_mounts "$dev"
      [ "${#M_TARGET[@]}" -eq 0 ] && break
      if ! bsr_udisks unmount -b "$dev"; then
         bsr_mounts "$dev"
         [ "${#M_TARGET[@]}" -eq 0 ] && break
         return 1
      fi
   done
   bsr_mounts "$dev"
   if [ "${#M_TARGET[@]}" -gt 0 ]; then
      UD_ERROR=still-mounted
      printf -v UD_MESSAGE $"%s is still mounted at %s after being unmounted" "$dev" "${M_TARGET[0]}"
      return 1
   fi
   bsr_wait_released "$dev" "${daemons[@]}"
}

# Services that systemd stops when this mount point goes away (BindsTo=,
# Requires=, PartOf=, Requisite=, RequiresMountsFor= on its .mount unit).
# Fills DEP_UNITS, DEP_NAMES (description) and DEP_BACK (1 when systemd
# starts the service again with the mount: WantedBy=/RequiredBy= it) for the
# active ones.
bsr_mount_dependents() {
   local mp="$1" unit u key val deps wanted state desc
   DEP_UNITS=() DEP_NAMES=() DEP_BACK=()
   command -v systemctl >/dev/null || return 0
   unit="$(systemd-escape --path --suffix=mount -- "$mp" 2>/dev/null)" || return 0
   while read -r u; do
      u="${u//[^A-Za-z0-9@._:\\-]/}"
      [[ $u == *.service ]] || continue
      deps="" wanted="" state="" desc=""
      while IFS='=' read -r key val; do
         case "$key" in
            Description) desc="$val"; continue ;;
            ActiveState) state="$val"; continue ;;
         esac
         # systemctl quotes names that contain escapes: "run-media-x\\x20y.mount"
         val="${val//\"/}"
         val="${val//\\\\/\\}"
         case "$key" in
            BindsTo | Requires | PartOf | Requisite) deps+=" $val" ;;
            WantedBy | RequiredBy) wanted+=" $val" ;;
         esac
      done < <(systemctl show -p BindsTo -p Requires -p PartOf -p Requisite -p WantedBy \
         -p RequiredBy -p ActiveState -p Description -- "$u" 2>/dev/null)
      [[ "$deps " == *" $unit "* ]] || continue
      [ "$state" = active ] || continue
      DEP_UNITS+=("$u") DEP_NAMES+=("${desc:-$u}")
      if [[ "$wanted " == *" $unit "* ]]; then DEP_BACK+=(1); else DEP_BACK+=(0); fi
   done < <(systemctl list-dependencies --reverse --plain --no-legend -- "$unit" 2>/dev/null)
}

# Make the current user owner of the root folder of a POSIX filesystem
# (not recursive), through the UDisks2 TakeOwnership API and polkit.
bsr_take_ownership() {
   local dev="$1"
   UD_ERROR="" UD_MESSAGE=""
   if ! bsr_udisks_object "$dev"; then
      UD_ERROR=no-object; return 1
   fi
   bsr_gdbus "$REPLY" org.freedesktop.UDisks2.Filesystem.TakeOwnership "{'recursive': <false>}"
}

# bsr_gdbus OBJECT METHOD ARGS...: call a UDisks2 method that udisksctl does
# not offer, keeping the D-Bus error name in UD_ERROR (as bsr_udisks does).
# Methods that wait for the hardware set BSR_GDBUS_TIMEOUT (seconds).
bsr_gdbus() {
   local obj="$1" method="$2" out
   shift 2
   UD_ERROR="" UD_MESSAGE=""
   out="$(gdbus call --system --timeout "${BSR_GDBUS_TIMEOUT:-120}" --dest org.freedesktop.UDisks2 \
      --object-path "$obj" --method "$method" "$@" 2>&1)" && return 0
   UD_MESSAGE="$out" UD_ERROR=unknown
   [[ $out =~ GDBus\.Error:([A-Za-z0-9_.]+) ]] && UD_ERROR="${BASH_REMATCH[1]}"
   return 1
}

# ---------------------------------------------------------------------------
# Drive health
#
# A failing SSD can stop answering (ATA timeouts, link resets) and then lock
# itself in a protection mode in which it acknowledges every write and keeps
# none: an installer cannot create partitions, and an erased partition table
# comes back. The kernel log shows the first part. Only what the kernel, udev
# and UDisks2 already know is read here: never the drive itself.

# Kernel messages of a drive that stopped answering: a command timed out and
# the link was reset (SATA), or the controller aborted a command (NVMe)
BSR_RE_TIMEOUT='failed command: |qc timeout|COMRESET failed|I/O (tag )?[0-9]+ .*timeout'
BSR_RE_SLOWLINK='limiting SATA link speed'
BSR_RE_MEDIUM='critical medium error|Medium Error|Unrecovered read error'
# How many resets of a USB port count as a problem: one or two are normal
# while a drive spins up or a program asks it for SMART data
BSR_USB_RESETS_ALERT=3

# Findings of the last bsr_drive_health (bsr_diag_doc reads them)
DH_FIND=() DH_DISK=""

# The port of a disk in kernel messages (REPLY, empty if none): ata1 for
# "ata1.00: failed command", nvme0 for "nvme nvme0: I/O 12 QID 3 timeout",
# 1-9.1 for "usb 1-9.1: reset high-speed USB device".
# Timeouts are reported on the port, never with the name of the disk.
bsr_drive_port() {
   local p
   REPLY=""
   p="$(readlink -f -- "/sys/block/${1##*/}" 2>/dev/null)"
   if [[ $p =~ /(ata[0-9]+)/ ]]; then
      REPLY="${BASH_REMATCH[1]}"
   elif [[ $p =~ /usb[0-9]+/(.*/)?([0-9]+-[0-9.]+):[0-9]+\.[0-9]+/ ]]; then
      REPLY="${BASH_REMATCH[2]}"
   elif [[ ${1##*/} =~ ^(nvme[0-9]+)n[0-9]+$ ]]; then
      REPLY="${BASH_REMATCH[1]}"
   fi
}

# bsr_drive_kmsg NAME_RE PORT: kernel messages of this boot about a disk,
# its partitions or its port (DKMSG). Fails when this user cannot read them.
bsr_drive_kmsg() {
   local re="$1"
   DKMSG=()
   [ -n "$2" ] && re+="|${2//./\\.}"
   command -v journalctl >/dev/null || return 1
   [ -n "$(journalctl -k -b -q -n 1 --no-pager 2>/dev/null)" ] || return 1
   mapfile -t DKMSG < <(journalctl -k -b -q --no-pager -o cat -n 400 --grep "\\b(${re})\\b" 2>/dev/null)
}

# bsr_udev_props DEV: the udev properties of a device (UP). ata_id publishes
# the ATA security state there, readable by every user.
declare -gA UP
bsr_udev_props() {
   local k v
   UP=()
   while IFS='=' read -r k v; do
      [ -n "$k" ] && UP[$k]="$v"
   done < <(udevadm info --query=property --name="$1" 2>/dev/null)
}

# bsr_udisks_drive DISK: the UDisks2 drive object of a disk (REPLY), as
# UDisks2 names it
bsr_udisks_drive() {
   local out
   bsr_udisks_object "$1" || return 1
   out="$(busctl --system get-property org.freedesktop.UDisks2 "$REPLY" org.freedesktop.UDisks2.Block Drive 2>/dev/null)"
   REPLY=""
   [[ $out =~ ^o\ \"(/org/freedesktop/UDisks2/drives/[A-Za-z0-9_]+)\"$ ]] || return 1
   REPLY="${BASH_REMATCH[1]}"
}

# bsr_drive_health DISK: what the drive and the kernel reported since the
# computer was started. Read-only, as the user. Sets:
#   DH_FIND       findings, most serious first: smart-failing timeouts
#                 io-errors slow-link usb-resets
#   DH_COUNT      kernel messages counted, by finding
#   DH_LINES      the kernel messages that were counted
#   DH_KLOG       1 when the kernel log could be read
#   DH_SMART      ok | failing | "" (not available)
#   DH_BAD        damaged sectors the drive counts (SMART): not a finding by
#                 itself, an SSD replaces a few of them in normal use
#   DH_PORT       ata1, nvme0... or ""
#   DH_ATA        1 for an ATA drive on an ATA/SATA port (not behind USB)
# What UDisks2 keeps of SMART without a password (internal ATA and NVMe drives;
# nothing through USB). "" when not known:
#   DH_HOURS      hours powered on       DH_TEMP     temperature now, °C
#   DH_ATTR_FAIL  ATA attributes below their threshold now
#   DH_ATTR_PAST  ATA attributes that were below it in the past
#   DH_NVME_WARN  NVMe critical warnings, as words ("" none)
#   DH_NVME_USED  NVMe life used, %      DH_NVME_MEDIA  NVMe media errors
#   DH_NVME_HOT   NVMe warning temperature, °C
declare -gA DH_COUNT
bsr_drive_health() {
   local disk="$1" kn="${1##*/}" l k n io_re off_re usb_re="" smart=() obj
   DH_DISK="$disk" DH_FIND=() DH_COUNT=() DH_LINES=() DH_KLOG=0 DH_SMART="" DH_BAD=0
   DH_ATA=0
   DH_HOURS="" DH_TEMP="" DH_ATTR_FAIL="" DH_ATTR_PAST="" DH_NVME_WARN="" DH_NVME_USED="" DH_NVME_MEDIA="" DH_NVME_HOT=""
   bsr_drive_port "$disk"; DH_PORT="$REPLY"
   # "I/O error, dev sda, sector 73448" and "Buffer I/O error on dev sda1"
   io_re="I/O error(,| on) dev ${kn}(p?[0-9]+)?(,|$)|$BSR_RE_MEDIUM"
   off_re="offline error, dev ${kn}(,|$)"
   # "usb 1-9.1: reset": exact port, so that 1-9.1.2 behind it does not count
   if [[ $DH_PORT == [0-9]* ]]; then
      usb_re="usb ${DH_PORT//./\\.}: (reset .*USB device|USB disconnect)"
   fi
   if bsr_drive_kmsg "${kn}(p?[0-9]+)?" "$DH_PORT"; then
      DH_KLOG=1
      for l in "${DKMSG[@]}"; do
         if [[ $l =~ $BSR_RE_TIMEOUT ]] || [[ $l =~ $off_re ]]; then k=timeouts
         elif [[ $l =~ $io_re ]]; then k=io-errors
         elif [ -n "$usb_re" ] && [[ $l =~ $usb_re ]]; then k=usb-resets
         elif [[ $l =~ $BSR_RE_SLOWLINK ]]; then k=slow-link
         else continue
         fi
         DH_COUNT[$k]=$((${DH_COUNT[$k]:-0} + 1))
         DH_LINES+=("$l")
      done
   fi

   bsr_udev_props "$disk"
   # A SATA drive in a USB enclosure also has ID_ATA, but UDisks2 reads SMART
   # of the drive only on an ATA port: only ID_BUS=ata counts
   [ "${UP[ID_ATA]:-0}" = 1 ] && [ "${UP[ID_BUS]:-}" = ata ] && DH_ATA=1
   if [ "$DH_ATA" = 1 ] && bsr_udisks_drive "$disk"; then
      mapfile -t smart < <(busctl --system get-property org.freedesktop.UDisks2 "$REPLY" org.freedesktop.UDisks2.Drive.Ata \
         SmartSupported SmartEnabled SmartFailing SmartNumBadSectors SmartPowerOnSeconds SmartTemperature \
         SmartNumAttributesFailing SmartNumAttributesFailedInThePast 2>/dev/null)
      if [ "${smart[0]:-}" = "b true" ] && [ "${smart[1]:-}" = "b true" ]; then
         DH_SMART=ok
         [ "${smart[2]:-}" = "b true" ] && DH_SMART=failing
         n="${smart[3]:-}"; n="${n#x }"
         [[ $n =~ ^[0-9]+$ ]] && DH_BAD="$n"
         n="${smart[4]:-}"; n="${n#t }"
         [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && DH_HOURS=$((n / 3600))
         # Kelvin, as a double; 0 when the drive does not say
         n="${smart[5]:-}"; n="${n#d }"; n="${n%%.*}"
         [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt 200 ] && DH_TEMP=$((n - 273))
         n="${smart[6]:-}"; n="${n#i }"
         [[ $n =~ ^[0-9]+$ ]] && DH_ATTR_FAIL="$n"
         n="${smart[7]:-}"; n="${n#i }"
         [[ $n =~ ^[0-9]+$ ]] && DH_ATTR_PAST="$n"
      fi
   elif [[ $kn == nvme* ]] && bsr_udisks_drive "$disk"; then
      bsr_drive_health_nvme "$REPLY"
   fi

   [ "$DH_SMART" = failing ] && DH_FIND+=(smart-failing)
   for k in timeouts io-errors slow-link; do
      [ -n "${DH_COUNT[$k]:-}" ] && DH_FIND+=("$k")
   done
   [ "${DH_COUNT[usb-resets]:-0}" -ge "$BSR_USB_RESETS_ALERT" ] && DH_FIND+=(usb-resets)
   return 0
}

# bsr_drive_health_nvme OBJECT: the health log of an NVMe drive, as UDisks2
# keeps it (read without a password; UDisks2 refreshes it by itself)
bsr_drive_health_nvme() {
   local obj="$1" props=() line n w
   local nv=org.freedesktop.UDisks2.NVMe.Controller
   mapfile -t props < <(busctl --system get-property org.freedesktop.UDisks2 "$obj" "$nv" \
      SmartUpdated SmartCriticalWarning SmartPowerOnHours SmartTemperature 2>/dev/null)
   # Never updated: UDisks2 has nothing to say yet
   n="${props[0]:-}"; n="${n#t }"
   [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || return 0
   DH_SMART=ok
   # as 2 "spare" "temperature"
   line="${props[1]:-}"
   if [[ $line =~ ^as\ [1-9] ]]; then
      for w in ${line#as * }; do DH_NVME_WARN+="${DH_NVME_WARN:+,}${w//\"/}"; done
   fi
   n="${props[2]:-}"; n="${n#t }"
   [[ $n =~ ^[0-9]+$ ]] && DH_HOURS="$n"
   n="${props[3]:-}"; n="${n#q }"
   [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt 200 ] && DH_TEMP=$((n - 273))
   # a{sv} 15 "avail_spare" y 100 "percent_used" y 5 ... "media_errors" t 0 "wctemp" q 356
   line="$(busctl --system call org.freedesktop.UDisks2 "$obj" "$nv" SmartGetAttributes 'a{sv}' 0 2>/dev/null)"
   [[ $line =~ \"percent_used\"\ y\ ([0-9]+) ]] && DH_NVME_USED="${BASH_REMATCH[1]}"
   [[ $line =~ \"media_errors\"\ t\ ([0-9]+) ]] && DH_NVME_MEDIA="${BASH_REMATCH[1]}"
   [[ $line =~ \"wctemp\"\ q\ ([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 273 ] && DH_NVME_HOT=$((BASH_REMATCH[1] - 273))
   return 0
}

# ---------------------------------------------------------------------------
# What a drive went through before this start of the computer

# Where the kernel publishes the filesystems it has mounted (tests use a copy)
BSR_SYS_FS=/sys/fs

# bsr_fs_errors DEV: the errors a mounted filesystem keeps on the drive itself,
# so that they survive restarts: the device statistics of Btrfs and the error
# count of ext4. They count since the filesystem was created, or since an
# administrator reset them (btrfs device stats -z, e2fsck). Read from /sys,
# without a password. Sets FE_TOTAL, FE_KINDS ("read 2, corruption 1") and
# FE_ID (the filesystem, to count it once). Fails when DEV is not a mounted
# Btrfs or ext4.
bsr_fs_errors() {
   local kn="$1" f st k n dir order=(write read flush corruption generation)
   local -A c=()
   FE_TOTAL=0 FE_KINDS="" FE_ID=""
   # /dev/mapper/NAME is a link to /dev/dm-N, the name the kernel uses
   [ -L "$kn" ] && kn="$(readlink -f -- "$kn" 2>/dev/null)"
   kn="${kn##*/}"
   [ -n "$kn" ] || return 1
   if [ -r "$BSR_SYS_FS/ext4/$kn/errors_count" ]; then
      n=""
      { read -r n < "$BSR_SYS_FS/ext4/$kn/errors_count"; } 2>/dev/null
      [[ $n =~ ^[0-9]+$ ]] || n=0
      FE_ID="ext4/$kn" FE_TOTAL="$n"
      [ "$n" -gt 0 ] && FE_KINDS="ext4 $n"
      return 0
   fi
   for f in "$BSR_SYS_FS"/btrfs/*/devices/"$kn"; do
      [ -e "$f" ] || continue
      dir="${f%/devices/*}" FE_ID="btrfs/${dir##*/}"
      # devinfo/DEVID/error_stats: "read_errs 0" lines, for every device of
      # the filesystem (a filesystem over several drives counts for each)
      for st in "$dir"/devinfo/*/error_stats; do
         [ -r "$st" ] || continue
         while read -r k n; do
            [[ $n =~ ^[0-9]+$ ]] || continue
            [ "$n" -gt 0 ] || continue
            k="${k%_errs}"
            c[$k]=$((${c[$k]:-0} + n)) FE_TOTAL=$((FE_TOTAL + n))
         done < "$st"
      done
      for k in "${order[@]}"; do
         [ -n "${c[$k]:-}" ] && FE_KINDS+="${FE_KINDS:+, }$k ${c[$k]}"
      done
      return 0
   done
   return 1
}

# bsr_drive_fs_errors DISK [DEV...]: bsr_fs_errors for every filesystem of a
# drive, or of the devices given (the drive manager already knows them).
# FSE_TOTAL, and FSE_LIST ("/dev/sda2: read 2") for those with errors.
bsr_drive_fs_errors() {
   local d fs_seen=" " devs=("${@:2}")
   FSE_TOTAL=0 FSE_LIST=()
   if [ "${#devs[@]}" -eq 0 ]; then
      bsr_drive_members "$1"
      devs=("${DRIVE_DEVS[@]}")
   fi
   for d in "${devs[@]}"; do
      bsr_fs_errors "$d" || continue
      [[ $fs_seen == *" $FE_ID "* ]] && continue
      fs_seen+="$FE_ID "
      [ "$FE_TOTAL" -gt 0 ] || continue
      FSE_TOTAL=$((FSE_TOTAL + FE_TOTAL))
      FSE_LIST+=("$d: $FE_KINDS")
   done
   return 0
}

# How far back the starts of the computer are read for an internal drive
BSR_HISTORY_BOOTS=5 BSR_HISTORY_DAYS=30

# bsr_drive_ident PORT BOOT: what the kernel found on an internal port in one
# start of the computer (REPLY): "model, firmware" of an ATA drive, the PCI
# function of an NVMe controller. Reads the lines of bsr_drive_boot_kmsg
# (BKMSG), or this start when BOOT is empty.
bsr_drive_ident() {
   local port="$1" l
   REPLY=""
   if [ -z "$2" ] && [[ $port == nvme* ]]; then
      l="$(readlink -f -- "/sys/class/nvme/$port/device" 2>/dev/null)"
      REPLY="${l##*/}"
      [ -n "$REPLY" ]
      return
   fi
   [ -n "$2" ] || bsr_drive_boot_kmsg "$port" "" || return 1
   for l in "${BKMSG[@]}"; do
      # "ata2.00: ATA-10: WDC WD10SPZX-24Z10T0, 01.01A01, max UDMA/133"
      if [[ $l =~ (^|[^0-9a-z])$port\.00:\ ATA-[0-9]+:\ (.+),\ max\  ]]; then REPLY="${BASH_REMATCH[2]}"; return 0; fi
      # "nvme nvme0: pci function 0000:09:00.0"
      if [[ $l =~ nvme\ $port:\ pci\ function\ ([0-9a-f:.]+) ]]; then REPLY="${BASH_REMATCH[1]}"; return 0; fi
   done
   return 1
}

# bsr_drive_boot_kmsg PORT BOOT_ID: kernel messages of one start (this one
# when BOOT_ID is empty) about an internal port and the disk behind it (BKMSG)
bsr_drive_boot_kmsg() {
   local re
   BKMSG=()
   case "$1" in
      ata[0-9]*) re="${1}(\\.[0-9]+)?" ;;
      nvme[0-9]*) re="${1}(n[0-9]+(p[0-9]+)?)?" ;;
      *) return 1 ;;
   esac
   mapfile -t BKMSG < <(journalctl -k -b "${2:-0}" -q --no-pager -o short --grep "\\b(${re})\\b" 2>/dev/null)
   [ "${#BKMSG[@]}" -gt 0 ]
}

# The earlier starts of the computer, most recent first (BOOT_IDS): at most
# BSR_HISTORY_BOOTS, none older than BSR_HISTORY_DAYS, never this one
bsr_earlier_boots() {
   local now cur obj id last
   BOOT_IDS=()
   read -r cur < /proc/sys/kernel/random/boot_id 2>/dev/null
   cur="${cur//-/}"
   now="$(date +%s)"
   while IFS= read -r obj; do
      [[ $obj =~ \"boot_id\":\"([0-9a-f]{32})\" ]] || continue
      id="${BASH_REMATCH[1]}"
      [[ $obj =~ \"last_entry\":([0-9]+) ]] || continue
      last="${BASH_REMATCH[1]}"
      [ "$id" = "$cur" ] && continue
      [ $((last / 1000000)) -ge $((now - BSR_HISTORY_DAYS * 86400)) ] || continue
      BOOT_IDS=("$id" "${BOOT_IDS[@]}")
   done < <(journalctl --list-boots -o json -q --no-pager 2>/dev/null | tr '}' '\n')
   [ "${#BOOT_IDS[@]}" -gt "$BSR_HISTORY_BOOTS" ] && BOOT_IDS=("${BOOT_IDS[@]:0:$BSR_HISTORY_BOOTS}")
   [ "${#BOOT_IDS[@]}" -gt 0 ]
}

# bsr_drive_history DISK: errors of an internal drive in earlier starts of the
# computer. Only for ATA and NVMe ports: an internal drive stays on its port
# and the kernel names what it finds there at every start, so a message of
# an earlier start counts only when that start found the same model and
# firmware (ATA) or the same PCI function (NVMe) on the port. USB drives come
# and go and their names are reused: for them only this start is read.
# Earlier starts do not change, so what was found is kept for this start in
# the private runtime folder. Sets:
#   DHI_BOOTS  earlier starts read        DHI_BAD    starts with errors
#   DHI_COUNT  error messages             DHI_IO     of them, read failures
#   DHI_LINK   of them, connection errors (CRC, slowed link)
#   DHI_LINES  the last messages counted
# Fails when there is no history to read (not an internal drive, no
# earlier start in the journal, a journal this user cannot read).
bsr_drive_history() {
   local disk="$1" port sig id l k n file="" dir boot="" tmp seq
   local link_re='ICRC|limiting SATA link speed' io_re="$BSR_RE_MEDIUM|\\{ ?UNC|I/O error"
   DHI_BOOTS=0 DHI_BAD=0 DHI_COUNT=0 DHI_IO=0 DHI_LINK=0 DHI_LINES=()
   # bsr_drive_health of the same drive already found its port
   if [ "${DH_DISK:-}" = "$disk" ]; then port="$DH_PORT"; else bsr_drive_port "$disk"; port="$REPLY"; fi
   case "$port" in ata[0-9]* | nvme[0-9]*) ;; *) return 1 ;; esac
   command -v journalctl >/dev/null || return 1

   dir="${XDG_RUNTIME_DIR:-}"
   read -r boot < /proc/sys/kernel/random/boot_id 2>/dev/null
   bsr_diskseq "$disk"; seq="$REPLY"
   if [ -n "$dir" ] && [ -d "$dir" ] && [ -O "$dir" ] && [ -n "$boot" ] && [ -n "$seq" ]; then
      file="$dir/big-storage-rescue/history-${boot:0:8}-$port-$seq"
      if [ -r "$file" ]; then
         while IFS=' ' read -r k n; do
            case "$k" in
               boots) DHI_BOOTS="$n" ;; bad) DHI_BAD="$n" ;; count) DHI_COUNT="$n" ;;
               io) DHI_IO="$n" ;; link) DHI_LINK="$n" ;; line) DHI_LINES+=("$n") ;;
            esac
         done < "$file"
         [ "$DHI_BOOTS" -gt 0 ]
         return
      fi
   fi

   bsr_drive_ident "$port" "" || return 1
   sig="$REPLY"
   bsr_earlier_boots || return 1
   for id in "${BOOT_IDS[@]}"; do
      bsr_drive_boot_kmsg "$port" "$id" || continue
      if ! bsr_drive_ident "$port" "$id" || [ "$REPLY" != "$sig" ]; then continue; fi
      DHI_BOOTS=$((DHI_BOOTS + 1)) n=0
      for l in "${BKMSG[@]}"; do
         if [[ $l =~ $io_re ]]; then DHI_IO=$((DHI_IO + 1))
         elif [[ $l =~ $link_re ]]; then DHI_LINK=$((DHI_LINK + 1))
         elif [[ $l =~ $BSR_RE_TIMEOUT ]]; then :
         else continue
         fi
         n=$((n + 1))
         DHI_LINES+=("$l")
      done
      [ "$n" -gt 0 ] && DHI_BAD=$((DHI_BAD + 1))
      DHI_COUNT=$((DHI_COUNT + n))
   done
   [ "${#DHI_LINES[@]}" -gt 15 ] && DHI_LINES=("${DHI_LINES[@]: -15}")

   if [ -n "$file" ] && mkdir -p -- "${file%/*}" 2>/dev/null && tmp="$(mktemp -- "$file.XXXXXX" 2>/dev/null)"; then
      {
         printf 'boots %s\nbad %s\ncount %s\nio %s\nlink %s\n' "$DHI_BOOTS" "$DHI_BAD" "$DHI_COUNT" "$DHI_IO" "$DHI_LINK"
         for l in "${DHI_LINES[@]}"; do printf 'line %s\n' "${l//[[:cntrl:]]/?}"; done
      } > "$tmp"
      mv -f -- "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp"
   fi
   [ "$DHI_BOOTS" -gt 0 ]
}

# bsr_drive_past DISK [DEV...]: bsr_drive_history and bsr_drive_fs_errors.
# DHI_PAST is 1 when the earlier starts count as a problem: one message in a
# few days can be a glitch, a read failure never is.
bsr_drive_past() {
   DHI_PAST=0
   bsr_drive_history "$1" || DHI_IO=0 DHI_COUNT=0
   if [ "$DHI_IO" -gt 0 ] || [ "$DHI_COUNT" -ge 3 ]; then DHI_PAST=1; fi
   bsr_drive_fs_errors "$@"
}

# ---------------------------------------------------------------------------
# Privileged inspection (root, through pkexec): processes of every user
# holding a mount point. Prints lsof field output for bsr_holders.
bsr_privileged_holders() {
   local mp="$1"
   [ "$EUID" -eq 0 ] || { bsr_warn "must run as root"; return 1; }
   [[ $mp == /* ]] || { bsr_warn "not an absolute path"; return 1; }
   # Only an exact, block-device backed mount point is accepted
   local src
   src="$(findmnt -n -o SOURCE --mountpoint "$mp" 2>/dev/null | head -n1)"
   src="${src%%\[*}"
   [[ $src == /dev/* ]] || { bsr_warn "not a mount point of a local device"; return 1; }
   # The running system is never removed: no reason to list all its processes
   bsr_is_system_mount "$mp" && { bsr_warn "refused: a mount of the running system"; return 1; }
   lsof -w -F pcuLftan -- "$mp" 2>/dev/null
   return 0
}
