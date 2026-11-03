# shellcheck shell=bash
#
# Big Storage Rescue: the storage of the running system. Checks that only mean
# something for the drive the computer started from: a full system, Btrfs
# without room to grow, and partitions that os-prober left mounted when the
# boot menu was updated. An external or secondary drive does not run the
# system, so its free space is nobody's problem but its owner's: none of this
# is asked about it, except the os-prober leftovers, which can hold any
# partition.
#
# Read-only, as the user: the mount table, statfs of the system mounts and
# /sys. Nothing is changed and nothing is offered to be: what to do is
# explained, and what needs an administrator is said as a command to read,
# never run from here.

# The findings of the last bsr_sc_run: key, level (critical | attention),
# a sentence and what to do
SC_KEY=() SC_LEVEL=() SC_TEXT=() SC_HELP=()

bsr_sc_add() { SC_KEY+=("$1") SC_LEVEL+=("$2") SC_TEXT+=("$3") SC_HELP+=("$4"); }

# Filesystems that hold no files of their own
BSR_SC_PSEUDO=" tmpfs devtmpfs ramfs squashfs overlay erofs iso9660 zram fuse.portal "

# bsr_sc_on_disk SOURCE: whether a mount source is on the drive of the last
# bsr_sc_run (always true without one)
bsr_sc_on_disk() {
   [ -z "$SC_DISK" ] && return 0
   [[ " ${DRIVE_DEVS[*]} " == *" $1 "* ]]
}

# bsr_sc_run [DISK]: the checks, for the system on DISK, or for the whole
# running system without one. Fills SC_*; SC_SYSTEM is 1 when DISK (or any
# drive) holds a filesystem of the running system.
bsr_sc_run() {
   SC_KEY=() SC_LEVEL=() SC_TEXT=() SC_HELP=() SC_SYSTEM=0 SC_DISK="${1:-}"
   [ -n "$SC_DISK" ] && bsr_drive_members "$SC_DISK"
   bsr_sc_space
   bsr_sc_osprober
   return 0
}

# bsr_sc_statfs TARGET...: "BLOCK_SIZE BLOCKS AVAILABLE TARGET" for each.
# statfs is asked of these mounts only, and with a limit: a mount whose driver
# is stuck (FUSE on a failing disk, a share that went away) hangs whoever asks
# it, and a question about every mount would hang with it
bsr_sc_statfs() {
   timeout "${BSR_STATFS_TIMEOUT:-5}" stat -f -c '%S %b %a %n' -- "$@" 2>/dev/null
}

# Free space of each filesystem of the running system, and the room Btrfs
# has left to grow. A full system makes programs fail, updates break halfway
# and settings get lost; /boot without room makes a kernel update fail.
bsr_sc_space() {
   local target src fs bs blocks bavail size avail seen=" " srcs=() targets=() i list s t
   local -A tg=() sz=() av=() fst=() of=()
   # The mount table alone: no statfs yet
   while read -r target src fs _; do
      target="${target//\\x20/ }"
      bsr_is_system_mount "$target" || continue
      [[ $BSR_SC_PSEUDO == *" $fs "* ]] && continue
      src="${src%%\[*}"
      [[ $src == /dev/* ]] || continue
      bsr_sc_on_disk "$src" || continue
      SC_SYSTEM=1 of[$target]="$src" fst[$src]="$fs"
      targets+=("$target")
   done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null)
   [ "${#targets[@]}" -gt 0 ] || return 0
   while read -r bs blocks bavail target; do
      src="${of[$target]:-}"
      [ -n "$src" ] || continue
      [[ $bs =~ ^[0-9]+$ && $blocks =~ ^[0-9]+$ && $bavail =~ ^[0-9]+$ ]] || continue
      size=$((bs * blocks)) avail=$((bs * bavail))
      [ "$size" -gt 0 ] || continue
      if [[ $seen != *" $src "* ]]; then
         seen+="$src " srcs+=("$src") sz[$src]="$size" av[$src]="$avail"
      fi
      tg[$src]+="${tg[$src]:+, }$target"
   done < <(bsr_sc_statfs "${targets[@]}")

   for src in "${srcs[@]}"; do
      size="${sz[$src]}" avail="${av[$src]}" list="${tg[$src]}"
      bsr_human_size "$avail"; s="$REPLY"
      bsr_human_size "$size"; t="$REPLY"
      # Percentages for small filesystems (/boot, the EFI partition), a cap
      # for large ones: 10 % of 4 TB is plenty of room
      if [ $((avail * 100)) -lt $((size * 3)) ] && [ "$avail" -lt $((2 * 1024 ** 3)) ]; then
         printf -v i $"The system is out of space on %s: only %s free of %s." "$list" "$s" "$t"
         bsr_sc_space_help "$list"
         bsr_sc_add space-full critical "$i" "$REPLY"
      elif [ $((avail * 100)) -lt $((size * 10)) ] && [ "$avail" -lt $((20 * 1024 ** 3)) ]; then
         printf -v i $"The system is running out of space on %s: %s free of %s." "$list" "$s" "$t"
         bsr_sc_space_help "$list"
         bsr_sc_add space-low attention "$i" "$REPLY"
      fi
      [ "${fst[$src]}" = btrfs ] && bsr_sc_btrfs "$src" "$list"
   done
}

bsr_sc_space_help() {
   case "$1" in
      /boot*)
         REPLY=$"Remove kernels that are no longer used, so that the next update has room for the new one." ;;
      *)
         REPLY=$"Free space: empty the trash, move large files to another drive and remove programs you do not use. With Btrfs, old snapshots (Timeshift, Snapper) keep deleted files: removing old snapshots gives that space back." ;;
   esac
}

# bsr_sc_btrfs DEV TARGETS: Btrfs gives space to data and metadata in large
# chunks. When every byte of the drive went to a chunk and the metadata chunks
# are full, it reports "no space left" while free space is still shown.
bsr_sc_btrfs() {
   local dev="$1" list="$2" kn f dir n total=0 alloc=0 k mtotal=0 mused=0 s msg help level
   kn="$(readlink -f -- "$dev" 2>/dev/null)"; kn="${kn##*/}"
   for f in "$BSR_SYS_FS"/btrfs/*/devices/"$kn"; do
      [ -e "$f" ] || return 0
      dir="${f%/devices/*}"
   done
   [ -n "${dir:-}" ] || return 0
   for f in "$dir"/devices/*/size; do
      n=""; { read -r n < "$f"; } 2>/dev/null
      [[ $n =~ ^[0-9]+$ ]] && total=$((total + n * 512))
   done
   for k in data metadata system; do
      n=""; { read -r n < "$dir/allocation/$k/disk_total"; } 2>/dev/null
      [[ $n =~ ^[0-9]+$ ]] && alloc=$((alloc + n))
   done
   { read -r mtotal < "$dir/allocation/metadata/total_bytes"; } 2>/dev/null
   { read -r mused < "$dir/allocation/metadata/bytes_used"; } 2>/dev/null
   [[ $mtotal =~ ^[0-9]+$ && $mused =~ ^[0-9]+$ ]] || mtotal=0 mused=0
   [ "$total" -gt 0 ] && [ "$alloc" -gt 0 ] && [ "$alloc" -le "$total" ] || return 0
   n=$((total - alloc))
   [ "$n" -lt $((1024 ** 3)) ] && [ $((n * 20)) -lt "$total" ] || return 0
   bsr_human_size "$n"; s="$REPLY"
   level=attention
   printf -v msg $"The Btrfs filesystem of %s has almost no unallocated space left (%s). It can then report 'no space left' even when free space is shown." "$list" "$s"
   # Metadata almost full as well: the next chunk it needs cannot be made
   if [ "$mtotal" -gt 0 ] && [ $((mused * 10)) -ge $((mtotal * 9)) ]; then
      level=critical
      msg+=" "$"Its metadata is also almost full: writing may fail at any moment."
   fi
   printf -v help $"Remove old snapshots and files first. Then, if the drive itself reports no problems, an administrator can compact the filesystem while the system runs: sudo btrfs balance start -dusage=50 %s" "${list%%,*}"
   bsr_sc_add btrfs-unallocated "$level" "$msg" "$help"
}

# Partitions os-prober left mounted: it looks for other systems when the boot
# menu is updated, and sometimes does not unmount what it looked at. Such a
# partition cannot be removed or checked until it is released, and a Btrfs
# one may even stay mounted with writing enabled.
bsr_sc_osprober() {
   local target src devs=() msg help
   while read -r target src _; do
      [[ $target == /var/lib/os-prober/* ]] || continue
      src="${src%%\[*}"
      bsr_sc_on_disk "$src" || continue
      [[ " ${devs[*]} " == *" $src "* ]] || devs+=("$src")
   done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null)
   [ "${#devs[@]}" -gt 0 ] || return 0
   printf -v msg $"os-prober left %s mounted after updating the boot menu." "${devs[*]}"
   help=$"Nothing is lost, and the partition is released at the next restart; until then it cannot be removed or checked. An administrator can release it now: sudo umount -R /var/lib/os-prober/mount"
   bsr_sc_add os-prober attention "$msg" "$help"
}

# The findings as a part of the current document (bsr_doc_*). With SYSTEM=1
# also says that nothing was found.
bsr_sc_doc() {
   local i
   if [ "${#SC_KEY[@]}" -eq 0 ]; then
      [ "${1:-}" = 1 ] && bsr_doc_p $"The storage of the running system: enough free space, nothing left mounted by mistake."
      return 0
   fi
   bsr_doc_p $"The storage of the running system:"
   for i in "${!SC_KEY[@]}"; do
      bsr_doc_li "${SC_TEXT[i]} ${SC_HELP[i]}"
   done
}

# "system":[...] for the JSON of a drive
bsr_sc_json() {
   local i first=1 out=""
   for i in "${!SC_KEY[@]}"; do
      [ "$first" = 1 ] && first=0 || out+=","
      out+="$(bsr_jo key "${SC_KEY[i]}" level "${SC_LEVEL[i]}" text "${SC_TEXT[i]}" help "${SC_HELP[i]}")"
   done
   printf '"system":[%s],"holds_system":%s' "$out" "$([ "$SC_SYSTEM" = 1 ] && echo true || echo false)"
}
