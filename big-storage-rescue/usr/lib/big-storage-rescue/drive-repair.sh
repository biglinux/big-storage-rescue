# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # RP_*, JC, JS are read across functions; DS_LEVEL comes from drive-diag.sh
#
# Big Storage Rescue drive manager: repairing a memory card or a USB drive.
#
# Everything else in Big Storage Rescue only reads the drive it works on. This
# is the one exception, and it is kept apart:
#   - it is for removable drives only (USB, SD cards), never a disk inside the
#     computer, never a drive of the running system;
#   - it erases the whole drive, and says so before anything is done: the
#     window asks for a confirmation, the terminal for the name of the device,
#     and polkit for the administrator password, every time;
#   - the writing is done by bsr-repair-helper alone, a program with a polkit
#     action of its own. This file only checks, explains and follows the work.
#
# What a repair does (docs/22-repair.md): measures the real capacity (f3probe),
# writes and reads back the surface, builds a partition table that leaves out
# what failed, and creates a filesystem. It is a job like a copy: it keeps
# working with the window closed, and its report stays.
#
# A repair is never resumed: a card reader keeps its name and serial number
# when the card in it is swapped, so a resume could erase another card.

# Tools are looked up through this function: the tests replace it
bsr_rp_have() { command -v "$1" >/dev/null; }

bsr_rp_mkfs_tool() {
   case "$1" in
      fat32) REPLY=mkfs.fat ;;
      exfat) REPLY=mkfs.exfat ;;
      ext4) REPLY=mkfs.ext4 ;;
      *) REPLY="" ;;
   esac
}

# The package of a tool, as a person installs it on Arch and Manjaro
bsr_rp_package() {
   case "$1" in
      mkfs.fat) REPLY=dosfstools ;;
      mkfs.exfat) REPLY=exfatprogs ;;
      mkfs.ext4) REPLY=e2fsprogs ;;
      f3probe) REPLY=f3 ;;
      python3) REPLY=python ;;
      pkexec) REPLY=polkit ;;
      *) REPLY=util-linux ;;
   esac
}

# FAT32 up to 32 GiB, as cards are sold and as cameras, car radios and older
# devices want; exFAT above, where FAT32 is not the norm
bsr_rp_auto_fs() {
   if [ "${1:-0}" -le $((32 * 1024 * 1024 * 1024)) ] || ! bsr_rp_have mkfs.exfat; then REPLY=fat32; else REPLY=exfat; fi
}

# bsr_rp_label FS TEXT: a volume name every system accepts (REPLY): letters,
# digits, - and _, as long as the filesystem allows; FAT in capitals
bsr_rp_label() {
   local fs="$1" text="$2" max=16
   case "$fs" in fat32) max=11 ;; exfat) max=15 ;; esac
   text="${text// /_}"
   # globasciiranges (on since bash 5): A-Z is ASCII, accented letters go too
   text="${text//[^A-Za-z0-9_-]/}"
   text="${text:0:$max}"
   [ "$fs" = fat32 ] && text="${text^^}"
   REPLY="${text:-DRIVE}"
}

bsr_rp_err_text() {
   case "$1" in
      repair-system) REPLY=$"This drive holds the running system. It is never erased here." ;;
      repair-internal) REPLY=$"Only memory cards and USB drives can be repaired here. A disk inside the computer is never erased by Big Storage Rescue." ;;
      repair-emmc) REPLY=$"This is flash memory built into the computer (eMMC), not a card. It is never erased here." ;;
      repair-not-own) REPLY=$"This disk image is not a file of yours." ;;
      repair-optical) REPLY=$"An optical disc cannot be repaired here." ;;
      repair-small) REPLY=$"This drive is too small to be repaired (at least 80 MB)." ;;
      repair-read-only) REPLY=$"This drive does not accept writing: its lock switch is on, or writing was blocked on it. Unlock it, or disconnect and connect it again." ;;
      repair-mounted) REPLY=$"Volumes of this drive are mounted. Unmount them first." ;;
      repair-in-use) REPLY=$"A repair of this drive is already running." ;;
      repair-confirm) REPLY=$"A repair erases the whole drive: confirm it with --yes, or run it in a terminal to type the name of the device." ;;
      repair-no-tool) REPLY=$"A tool needed for the repair is not installed." ;;
      *) bsr_cp_err_text "$1" ;;
   esac
}

bsr_rp_err_rc() {
   case "$1" in
      repair-no-tool) REPLY=25 ;;
      repair-mounted) REPLY=3 ;;
      repair-in-use) REPLY=10 ;;
      repair-confirm) REPLY=2 ;;
      *) bsr_cp_err_rc "$1" ;;
   esac
}

bsr_rp_warn_text() {
   case "$1" in
      has-data) REPLY=$"Everything on this drive will be erased: its volumes, files and partitions. Copy what matters first." ;;
      risky) REPLY=$"This drive reported problems. If it holds files you need, recover them first: a repair erases them for good." ;;
      no-f3) REPLY=$"f3 is not installed (package f3), so the real capacity is not measured: a counterfeit card is detected, but its size cannot be told. Installing it is recommended." ;;
      full-slow) REPLY=$"The complete test writes and reads every block. On a slow card it can take hours." ;;
      exfat-old) REPLY=$"Some older devices (cameras, car radios, TVs) do not read exFAT. FAT32 works everywhere, with files up to 4 GB." ;;
      ext4-linux) REPLY=$"ext4 is read by Linux only. Windows, macOS, phones and cameras will not open it." ;;
      fat-4g) REPLY=$"FAT32 cannot store files of 4 GB or more." ;;
      *) REPLY="$1" ;;
   esac
}

# The reason a finished repair gives (job reason)
bsr_rp_reason_text() {
   case "$1" in
      repair-fake) REPLY=$"This drive is counterfeit: it announces more space than it really has. It was set up to use only the real part, and works now." ;;
      repair-worn) REPLY=$"Part of this drive failed the test. It was left out, and the rest works now. Keep a copy of what you put on it: it may get worse." ;;
      repair-damaged) REPLY=$"This drive can no longer keep data: writing to it fails. It cannot be repaired. Replace it." ;;
      repair-inconsistent) REPLY=$"The drive gave back other data than was written: it may be counterfeit. Install f3 (package f3) to measure its real capacity, then repair it again." ;;
      repair-cancelled) REPLY=$"The repair was stopped. The drive was partly erased and has no usable filesystem: repair it again before using it." ;;
      repair-failed) REPLY=$"The repair stopped with an error. See the log. The drive may have no usable filesystem until it is repaired again." ;;
      repair-replaced) REPLY=$"The drive was disconnected or replaced before the repair started. Nothing was done." ;;
      repair-mounted-now) REPLY=$"Something mounted the drive before the repair started. Nothing was done." ;;
      repair-tool-missing) REPLY=$"A tool needed for the repair is not installed. See the log." ;;
      *) REPLY="" ;;
   esac
}

# bsr_rp_eligible DISK: can this drive be repaired here at all? RP_ERR when not
bsr_rp_eligible() {
   local d="$1" kind backing
   RP_ERR=""
   # The running system first: that is the reason a person must hear
   if bsr_system_use "$d"; then RP_ERR=repair-system; return 1; fi
   bsr_dv_kind "$d"; kind="$REPLY"
   case "$kind" in
      optical) RP_ERR=repair-optical; return 1 ;;
      emmc) RP_ERR=repair-emmc; return 1 ;;
      image)
         backing="$(cat "/sys/block/${d##*/}/loop/backing_file" 2>/dev/null)"
         if [ -z "$backing" ] || [ "$(stat -c %u -- "$backing" 2>/dev/null)" != "$EUID" ]; then RP_ERR=repair-not-own; return 1; fi
         ;;
      usb | sd) ;;
      *) [ "${DV[$d|RM]:-0}" = 1 ] || { RP_ERR=repair-internal; return 1; } ;;
   esac
   [ "${DV[$d|SIZE]:-0}" -ge $((80 * 1000 * 1000)) ] 2>/dev/null || { RP_ERR=repair-small; return 1; }
   [ "${DV[$d|RO]:-0}" = 1 ] && { RP_ERR=repair-read-only; return 1; }
   return 0
}

# bsr_rp_refusal JSON KEY [EXTRA_JSON]: a refusal, for a person or as data
bsr_rp_refusal() {
   local json="$1" key="$2" extra="${3:-}" text rc
   bsr_rp_err_text "$key"; text="$REPLY"
   bsr_rp_err_rc "$key"; rc="$REPLY"
   if [ "$json" = 1 ]; then
      printf '{%s,%s,%s%s,"warnings":[]}\n' "$(bsr_jo_inner error "$key" error_text "$text")" "$(bsr_jb ok 0)" "$(bsr_jn exit "$rc")" "${extra:+,$extra}"
   else
      printf '%s\n' "$text" >&2
   fi
   return "$rc"
}

bsr_rp_warnings_json() {
   local w out="" sep=""
   for w in "$@"; do
      bsr_rp_warn_text "$w"
      out+="$sep$(bsr_jo key "$w" text "$REPLY")"
      sep=","
   done
   printf '%s' "$out"
}

# A rough time, in seconds: f3probe takes a few minutes; the complete test
# writes everything at about 6 MB/s and reads it at about 18 MB/s, what a
# slow card does (a good one is many times faster)
bsr_rp_estimate() {
   local size="$1" mode="$2"
   if [ "$mode" = full ]; then REPLY=$((180 + size / 6000000 + size / 18000000))
   else REPLY=$((180 + 100 * 1024 * 1024 / 4000000))
   fi
}

# Is a repair of this disk running? (another job, same device)
bsr_rp_running() {
   local d dev="$1"
   [ -d "$BSR_JOBS" ] || return 1
   for d in "$BSR_JOBS"/*/; do
      d="${d%/}"
      [ -f "$d/job.conf" ] || continue
      grep -qx 'KIND=repair' "$d/job.conf" || continue
      grep -qxF "DEVICE=$dev" "$d/job.conf" || continue
      bsr_job_state_load "$d" || continue
      case "${JS[STATE]}" in pending | running | stopping) return 0 ;; esac
   done
   return 1
}

# big-storage-rescue --cli repair TARGET [options]
bsr_rp_cmd() {
   local target="" mode=quick fs=auto label="" margin=8 expect="" dry=0 nowait=0 json=0 yes=0
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --mode) mode="${2:-}"; shift ;;
         --filesystem) fs="${2:-}"; shift ;;
         --label) label="${2:-}"; shift ;;
         --margin-mib) margin="${2:-}"; shift ;;
         --expect-diskseq) expect="${2:-}"; shift ;;
         --dry-run) dry=1 ;;
         --no-wait) nowait=1 ;;
         --yes) yes=1 ;;
         --json) json=1 ;;
         -*) bsr_drive_badarg "$1"; return 2 ;;
         *) [ -z "$target" ] || { bsr_drive_badarg "$1"; return 2; }; target="$1" ;;
      esac
      shift
   done
   [ -n "$target" ] || { printf '%s\n' $"Name the drive to repair, such as /dev/sdb." >&2; return 2; }
   case "$mode" in quick | full) ;; *) bsr_drive_badarg "--mode $mode"; return 2 ;; esac
   case "$fs" in auto | fat32 | exfat | ext4) ;; *) bsr_drive_badarg "--filesystem $fs"; return 2 ;; esac
   [[ $margin =~ ^[0-9]+$ ]] && [ "$margin" -le 1024 ] || { bsr_drive_badarg "--margin-mib $margin"; return 2; }

   local rc
   bsr_drive_disk "$target"; rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   local disk="$DD_DISK"
   # The whole drive, whatever part of it was named
   bsr_dv_disks_of "$disk" && [ "${#DV_DISKS[@]}" -eq 1 ] && disk="${DV_DISKS[0]}"
   if [ -n "$expect" ]; then
      bsr_diskseq "$disk"
      [ "$REPLY" = "$expect" ] || { bsr_rp_refusal "$json" source-replaced; return; }
   fi
   bsr_rp_eligible "$disk" || { bsr_rp_refusal "$json" "$RP_ERR"; return; }
   local size="${DV[$disk|SIZE]}"

   [ "$fs" = auto ] && { bsr_rp_auto_fs "$size"; fs="$REPLY"; }
   [ -n "$label" ] || label="${DV[$disk|LABEL]:-}"
   if [ -z "$label" ]; then
      bsr_dv_tree "$disk"
      local p
      for p in "${DV_TREE[@]}"; do [ -n "${DV[$p|LABEL]:-}" ] && { label="${DV[$p|LABEL]}"; break; }; done
   fi
   bsr_dv_kind "$disk"
   [ -n "$label" ] || { [ "$REPLY" = sd ] && label=SDCARD || label=USB; }
   bsr_rp_label "$fs" "$label"; label="$REPLY"

   # Tools: the formatter, the partitioner, python for the test, pkexec
   local t missing=() pkgs=()
   bsr_rp_mkfs_tool "$fs"
   for t in "$REPLY" sfdisk wipefs python3 pkexec; do
      [ "$t" = pkexec ] && [ "$EUID" -eq 0 ] && continue
      bsr_rp_have "$t" || { missing+=("$t"); bsr_rp_package "$t"; pkgs+=("$REPLY"); }
   done
   if [ "${#missing[@]}" -gt 0 ]; then
      local list="" sep="" i
      for i in "${!missing[@]}"; do list+="$sep$(bsr_jo tool "${missing[i]}" package "${pkgs[i]}")"; sep=","; done
      if [ "$json" = 1 ]; then
         bsr_rp_refusal 1 repair-no-tool "\"missing\":[$list]"
      else
         bsr_rp_refusal 0 repair-no-tool
         printf '  %s\n' "${pkgs[@]}" >&2
      fi
      return 25
   fi

   # What is on it, and what is mounted
   local vols="" mounted=() p fsused sep="" has_data=0
   bsr_dv_tree "$disk"
   for p in "${DV_TREE[@]}"; do
      [ -n "${DV[$p|MOUNTPOINTS]:-}" ] && mounted+=("$p")
      [ -n "${DV[$p|FSTYPE]:-}" ] || continue
      has_data=1
      fsused="${DV[$p|FSUSED]:-}"
      vols+="$sep{$(bsr_jo_inner device "$p" label "${DV[$p|LABEL]:-}" fstype "${DV[$p|FSTYPE]:-}" mountpoint "${DV[$p|MOUNTPOINTS]%%$'\n'*}"),$(bsr_jn size "${DV[$p|SIZE]:-}" used "$fsused")}"
      sep=","
   done

   local warns=()
   [ "$has_data" = 1 ] && warns+=(has-data)
   bsr_ds_level "$disk"
   case "$DS_LEVEL" in critical | attention) [ "$has_data" = 1 ] && warns+=(risky) ;; esac
   bsr_rp_have f3probe || [ "${DV[$disk|TYPE]}" = loop ] || warns+=(no-f3)
   [ "$mode" = full ] && warns+=(full-slow)
   case "$fs" in
      exfat) warns+=(exfat-old) ;;
      ext4) warns+=(ext4-linux) ;;
      fat32) [ "$size" -gt $((32 * 1024 * 1024 * 1024)) ] && warns+=(fat-4g) ;;
   esac
   bsr_rp_estimate "$size" "$mode"; local estimate="$REPLY"
   bsr_diskseq "$disk"; local seq="$REPLY"
   bsr_dv_name "$disk"; local name="$REPLY"
   local f3=0
   bsr_rp_have f3probe && f3=1

   if [ "$dry" = 1 ]; then
      if [ "$json" = 1 ]; then
         local mlist="" m
         sep=""
         for m in "${mounted[@]}"; do bsr_js "$m"; mlist+="$sep$REPLY"; sep=","; done
         printf '{%s,%s,%s,"volumes":[%s],"mounted":[%s],"warnings":[%s]}\n' \
            "$(bsr_jo_inner error "" error_text "" device "$disk" name "$name" mode "$mode" filesystem "$fs" label "$label" level "$DS_LEVEL")" \
            "$(bsr_jb ok 1 f3 "$f3" has_data "$has_data")" \
            "$(bsr_jn exit 0 size "$size" diskseq "$seq" margin_mib "$margin" estimate "$estimate")" \
            "$vols" "$mlist" "$(bsr_rp_warnings_json "${warns[@]}")"
         return 0
      fi
      bsr_human_size "$size"
      printf '%s\n' $"Repair (this erases the whole drive):"
      printf '  %-18s %s (%s, %s)\n' $"Drive:" "$name" "$disk" "$REPLY"
      printf '  %-18s %s\n' $"Test:" "$([ "$mode" = full ] && printf '%s' $"complete: every block" || printf '%s' $"quick: samples of the surface")"
      printf '  %-18s %s\n' $"New filesystem:" "$fs ($label)"
      for t in "${warns[@]}"; do bsr_rp_warn_text "$t"; printf '  ! %s\n' "$REPLY"; done
      [ "${#mounted[@]}" -gt 0 ] && { bsr_rp_err_text repair-mounted; printf '  ! %s\n' "$REPLY"; }
      return 0
   fi

   if [ "${#mounted[@]}" -gt 0 ]; then bsr_rp_refusal "$json" repair-mounted; return; fi
   if bsr_rp_running "$disk"; then bsr_rp_refusal "$json" repair-in-use; return; fi
   if [ "$yes" != 1 ]; then
      # In a terminal, the person types the name of the device
      if [ "$json" = 0 ] && [ -t 0 ] && [ -r /dev/tty ]; then
         bsr_human_size "$size"
         printf $"Everything on %s (%s, %s) will be erased."'\n' "$name" "$disk" "$REPLY"
         printf $"To continue, type %s: "  "${disk##*/}"
         local answer=""
         read -r answer < /dev/tty
         [ "$answer" = "${disk##*/}" ] || { printf '%s\n' $"Nothing was done."; return 23; }
      else
         bsr_rp_refusal "$json" repair-confirm
         return
      fi
   fi

   local id dir now
   bsr_job_id; id="$REPLY"
   dir="$BSR_JOBS/$id"
   (umask 077; mkdir -p -- "$dir") || return 1
   printf -v now '%(%s)T' -1
   JC=([ID]="$id" [KIND]=repair [SOURCE]="$disk" [DEVICE]="$disk" [DEST]="" [SIZE]="$size" [DISKSEQ]="$seq"
      [NAME]="$name" [MODE]="$mode" [FS]="$fs" [LABEL]="$label" [MARGIN]="$margin" [CREATED]="$now" [LEVEL]="$DS_LEVEL")
   bsr_job_conf_save "$dir" || { rm -rf -- "$dir"; return 1; }
   JS=([STATE]=pending [PID]="" [PHASE]="" [STEPS]="")
   bsr_job_state_save "$dir"
   bsr_rec_image_start "$id" || return 1
   if [ "$json" = 1 ]; then bsr_jo id "$id" dir "$dir"; printf '\n'; return 0; fi
   printf $"Repair started: %s"'\n' "$id"
   if [ "$nowait" = 1 ]; then
      printf $"To follow it: big-storage-rescue --cli status %s --watch"'\n' "$id"
      return 0
   fi
   bsr_job_watch "$id" 1
}

# bsr_rp_read_out FILE: what the helper said so far, into JS
bsr_rp_read_out() {
   local file="$1" line k v steps="" phase="" s
   local -A step=()
   [ -r "$file" ] || return 0
   while IFS= read -r line; do
      case "$line" in
         "@phase "*) phase="${line#@phase }"; [ "$phase" = "done" ] || step[$phase]=running; JS[BYTES_NOW]=0 JS[BYTES_TOTAL]=0 ;;
         "@step "*) read -r _ k v <<< "$line"; step[$k]="$v" ;;
         "@progress "*) read -r _ k v <<< "$line"; JS[BYTES_NOW]="$k" JS[BYTES_TOTAL]="$v" ;;
         "@fact "*)
            read -r _ k v <<< "$line"
            [[ $v =~ ^-?[0-9]+$ ]] || continue
            case "$k" in
               announced) JS[ANNOUNCED]="$v" ;;
               real) JS[REAL]="$v" ;;
               tested) JS[TESTED]="$v" ;;
               bad) JS[BAD_BYTES]="$v" ;;
               first_bad) JS[FIRST_BAD]="$v" ;;
               usable) JS[USABLE]="$v" ;;
            esac
            ;;
         "@verdict "*) JS[VERDICT]="${line#@verdict }" ;;
         "@missing "*) JS[MISSING]="${line#@missing }" ;;
      esac
   done < <(grep -a '^@' -- "$file")
   for s in capacity surface partition format; do
      [ -n "${step[$s]:-}" ] && steps+="${steps:+,}$s:${step[$s]}"
   done
   JS[PHASE]="$phase" JS[STEPS]="$steps"
}

# The supervisor of a repair: runs the helper, publishes what it says
bsr_rp_supervise() {
   local id="$1" dir pid t0 now rc ctl dev
   bsr_job_dir "$id" || return 1
   dir="$REPLY"
   bsr_job_lock "$dir" || return 10
   bsr_job_conf_load "$dir"
   : > "$dir/control"
   rm -f -- "$dir/stop"
   JS=([STATE]=running [PID]="$$" [BYTES_TOTAL]=0 [BYTES_NOW]=0 [PHASE]="" [STEPS]="")
   bsr_proc_state "$$"; JS[PID_START]="$PROC_START"
   printf -v t0 '%(%s)T' -1
   bsr_job_state_save "$dir"
   trap ': > "$dir/stop"; printf "cancel\n" > "$dir/control"' TERM
   dev="${JC[DEVICE]}"
   : > "$dir/repair.out"
   bsr_helper repair "$dev" "${JC[DISKSEQ]}" "${JC[SIZE]}" "${JC[MODE]}" "${JC[FS]}" "${JC[LABEL]}" "${JC[MARGIN]}" "$dir/stop" >> "$dir/repair.out" 2>&1 &
   pid=$!
   while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      printf -v now '%(%s)T' -1
      JS[ELAPSED]=$((now - t0))
      bsr_rp_read_out "$dir/repair.out"
      ctl=""
      { read -r ctl < "$dir/control"; } 2>/dev/null
      if [ "$ctl" = cancel ]; then
         JS[STATE]=stopping
         : > "$dir/stop"
      fi
      bsr_job_state_save "$dir"
   done
   wait "$pid"; rc=$?
   printf -v now '%(%s)T' -1
   JS[ELAPSED]=$((now - t0))
   bsr_rp_read_out "$dir/repair.out"
   printf -v "JS[FINISHED]" '%(%s)T' -1
   ctl=""
   { read -r ctl < "$dir/control"; } 2>/dev/null
   case "$rc" in
      0)
         JS[STATE]=completed JS[REASON]=""
         case "${JS[VERDICT]:-}" in
            fake) JS[REASON]=repair-fake ;;
            worn) JS[REASON]=repair-worn ;;
         esac
         ;;
      126 | 127) JS[STATE]=failed JS[REASON]=not-authorized ;;
      4) JS[STATE]=failed JS[REASON]=repair-system ;;
      5) JS[STATE]=failed JS[REASON]=repair-replaced ;;
      6) JS[STATE]=failed JS[REASON]=repair-internal ;;
      7) JS[STATE]=failed JS[REASON]=repair-mounted-now ;;
      8) JS[STATE]=failed JS[REASON]=repair-damaged JS[VERDICT]=damaged ;;
      10) JS[STATE]=needs-attention JS[REASON]=repair-inconsistent ;;
      23) JS[STATE]=cancelled JS[REASON]=repair-cancelled ;;
      25) JS[STATE]=failed JS[REASON]=repair-tool-missing ;;
      *)
         if [ "$ctl" = cancel ]; then JS[STATE]=cancelled JS[REASON]=repair-cancelled
         else JS[STATE]=failed JS[REASON]=repair-failed
         fi
         ;;
   esac
   # A step left running when it stopped did not end well
   JS[STEPS]="${JS[STEPS]//:running/:failed}"
   bsr_job_state_save "$dir"
   bsr_job_report_write "$dir"
}

# What each step is called, for a person
bsr_rp_step_label() {
   case "$1" in
      capacity) REPLY=$"Measure the real capacity" ;;
      surface) REPLY=$"Test the surface" ;;
      partition) REPLY=$"Create a new partition table" ;;
      format) REPLY=$"Create the filesystem" ;;
      *) REPLY="$1" ;;
   esac
}

bsr_rp_step_state() {
   case "$1" in
      ok) REPLY=$"done" ;;
      failed) REPLY=$"failed" ;;
      skipped) REPLY=$"skipped" ;;
      running) REPLY=$"in progress" ;;
      *) REPLY="$1" ;;
   esac
}

# The progress of a repair, in the terminal (state already loaded)
bsr_rp_status_text() {
   local s k v pct
   printf '%-22s %s\n' $"Drive:" "${JC[NAME]//[[:cntrl:]]/?} (${JC[SOURCE]})"
   IFS=, read -r -a _steps <<< "${JS[STEPS]:-}"
   for s in "${_steps[@]}"; do
      k="${s%%:*}" v="${s#*:}"
      bsr_rp_step_label "$k"; local l="$REPLY"
      bsr_rp_step_state "$v"
      printf '  %-34s %s\n' "$l" "$REPLY"
   done
   if [ "${JS[BYTES_TOTAL]:-0}" -gt 0 ] && [ "${JS[STATE]}" = running ]; then
      pct=$((JS[BYTES_NOW] * 100 / JS[BYTES_TOTAL]))
      bsr_job_bar "$pct"; printf '%s\n' "$REPLY"
   fi
   bsr_fmt_time "${JS[ELAPSED]:-0}"; printf '%-22s %s\n' $"Elapsed:" "$REPLY"
   bsr_job_reason_text "${JS[REASON]:-}"
   [ -n "$REPLY" ] && printf '%s\n' "$REPLY"
   return 0
}

bsr_rp_report_text() {
   local dir="$1" s k v
   bsr_doc_kv $"Drive" "${JC[NAME]}"
   bsr_human_size "${JS[ANNOUNCED]:-${JC[SIZE]:-0}}"; bsr_doc_kv $"Announced capacity" "$REPLY"
   if [ -n "${JS[REAL]:-}" ]; then bsr_human_size "${JS[REAL]}"; bsr_doc_kv $"Real capacity" "$REPLY"; fi
   if [ -n "${JS[TESTED]:-}" ]; then
      bsr_human_size "${JS[TESTED]}"; bsr_doc_kv $"Tested" "$REPLY"
      bsr_human_size "${JS[BAD_BYTES]:-0}"; bsr_doc_kv $"Failed the test" "$REPLY"
   fi
   if [ -n "${JS[USABLE]:-}" ]; then bsr_human_size "${JS[USABLE]}"; bsr_doc_kv $"Usable now" "$REPLY"; fi
   bsr_doc_kv $"New filesystem" "${JC[FS]} (${JC[LABEL]})"
   bsr_fmt_time "${JS[ELAPSED]:-0}"; bsr_doc_kv $"Elapsed" "$REPLY"
   IFS=, read -r -a _steps <<< "${JS[STEPS]:-}"
   for s in "${_steps[@]}"; do
      k="${s%%:*}" v="${s#*:}"
      bsr_rp_step_label "$k"; local l="$REPLY"
      bsr_rp_step_state "$v"
      bsr_doc_kv "$l" "$REPLY"
   done
   bsr_ui_show info ""
   printf '\n%s %s\n' $"Log:" "$dir/repair.out"
}
