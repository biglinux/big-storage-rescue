# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # JC, JS, MP_*, BSR_RUN_* are shared with drive-copy.sh and drive-recovery.sh
#
# Big Storage Rescue drive manager: the readable parts of the files a copy
# could not finish.
#
# A copy goes file by file: rsync copies a whole file or nothing of it, and a
# file it gave up on, or set aside because it did not advance, is left out.
# That is the right first pass on a failing drive: thousands of good files are
# not held up by one bad one. Afterwards, those files can be salvaged: GNU
# ddrescue reads each one, as the user and through the mount, good areas
# first, and keeps a map of what it read:
#  - a pause, a power cut or a disconnection resumes from the map: what was
#    read is never read again, however large the file;
#  - what could not be read is left as zeros, and listed by byte range, so a
#    partly readable video or archive is saved with what it has;
#  - a file read completely goes where the copy would have put it; one with
#    unreadable areas goes to a folder of its own, with the list of what is
#    missing, never under the name of a good file.
# The source is only read (it is mounted read-only on a drive at risk), and
# there are no retries unless they are asked for: every extra read wears a
# failing drive.

BSR_SV_STAT_TIMEOUT=10

# bsr_sv_items DIR: the files a copy left out, relative to its source, once each
bsr_sv_items() {
   { cut -f2- -- "$1/failed.txt" 2>/dev/null; cat -- "$1/deferred.txt" 2>/dev/null; } | LC_ALL=C awk 'NF && !seen[$0]++'
}

# bsr_sv_stat FILE: "MODE SIZE MTIME" of a source file, with a limit: a file on
# a damaged area can hold even a stat for minutes. 124: no answer in time
bsr_sv_stat() {
   REPLY="$(LC_ALL=C timeout "$BSR_SV_STAT_TIMEOUT" stat -c '%f %s %Y' -- "$1" 2>/dev/null)"
   local rc=$?
   [ "$rc" -eq 124 ] && return 124
   [ -n "$REPLY" ]
}

# bsr_sv_is_file MODE: a regular file (MODE as stat %f, in hex)
bsr_sv_is_file() { [[ $1 =~ ^[0-9a-f]+$ ]] && [ $((16#$1 & 8#170000)) -eq $((8#100000)) ]; }

# big-storage-rescue --cli salvage COPY_ID [--retries N] [--dry-run] [--json] [--no-wait]
bsr_sv_cmd() {
   local parent="" retries=0 dry=0 json=0 nowait=0 pdir id dir now rel st mode size mtime stuck=0 total=0 i
   local -a R=() SZ=() MT=() warns=()
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --retries) retries="${2:-}"; shift ;;
         --dry-run) dry=1 ;;
         --json) json=1 nowait=1 ;;
         --no-wait) nowait=1 ;;
         -*) bsr_drive_badarg "$1"; return 2 ;;
         *) parent="$1" ;;
      esac
      shift
   done
   [[ $retries =~ ^[0-5]$ ]] || { bsr_drive_badarg "--retries $retries"; return 2; }
   bsr_job_dir "$parent" || { printf $"There is no job '%s'."'\n' "$parent" >&2; return 1; }
   pdir="$REPLY"
   bsr_job_conf_load "$pdir"
   bsr_job_state_load "$pdir"
   [ "${JC[KIND]:-copy}" = copy ] || { bsr_rec_refusal "$json" salvage-not-copy; return; }
   case "${JS[STATE]}" in
      pending | analyzing | running | verifying | stopping) bsr_rec_refusal "$json" job-running; return ;;
   esac
   command -v ddrescue >/dev/null || { bsr_rec_refusal "$json" no-ddrescue-files; return; }
   bsr_job_locate
   case "$?" in
      3) bsr_rec_refusal "$json" source-missing; return ;;
      4) bsr_rec_refusal "$json" dest-missing; return ;;
   esac
   local s="$BSR_RUN_S" d="$BSR_RUN_D"
   while IFS= read -r rel; do
      # Names come from rsync, relative to the source: never outside it
      [[ $rel == /* || /$rel/ == */../* ]] && continue
      bsr_sv_stat "$s/$rel"
      case "$?" in
         0) ;;
         124)
            stuck=$((stuck + 1))
            [ "$stuck" -ge 3 ] && { bsr_rec_refusal "$json" source-stuck; return; }
            continue
            ;;
         *) continue ;;
      esac
      read -r mode size mtime <<< "$REPLY"
      # Folders that could not be listed are not files to read; an empty file
      # has nothing to read
      if ! bsr_sv_is_file "$mode" || ! [ "$size" -gt 0 ] 2>/dev/null; then continue; fi
      R+=("$rel") SZ+=("$size") MT+=("$mtime")
      total=$((total + size))
   done < <(bsr_sv_items "$pdir")
   [ "${#R[@]}" -gt 0 ] || { bsr_rec_refusal "$json" nothing-to-salvage; return; }
   bsr_cp_avail "$d"
   local avail="$REPLY"
   if [[ $avail =~ ^[0-9]+$ ]] && [ "$avail" -lt "$total" ]; then
      bsr_rec_refusal "$json" no-space
      return
   fi
   warns+=(salvage-holes)
   [ "$retries" -gt 0 ] && warns+=(salvage-retries)
   if [ "$dry" = 1 ]; then
      if [ "$json" = 1 ]; then
         printf '{%s,%s,%s,"warnings":[%s]}\n' "$(bsr_jo_inner error "" error_text "" source "$s" destination "$d")" \
            "$(bsr_jb ok 1)" "$(bsr_jn exit 0 avail "${avail:-0}" total_bytes "$total" total_files "${#R[@]}")" "$(bsr_rec_warnings_json "${warns[@]}")"
         return 0
      fi
      bsr_human_size "$total"
      printf $"%s files (%s) would be read again with GNU ddrescue, from %s to %s."'\n' "${#R[@]}" "$REPLY" "$s" "$d"
      return 0
   fi
   bsr_job_id; id="$REPLY"
   dir="$BSR_JOBS/$id"
   (umask 077; mkdir -p -- "$dir/maps") || return 1
   # SIZE <tab> MTIME <tab> NAME, separated by NUL: a name may hold a tab
   for i in "${!R[@]}"; do printf '%s\t%s\t%s\0' "${SZ[i]}" "${MT[i]}" "${R[i]}"; done > "$dir/items0"
   printf -v now '%(%s)T' -1
   local name="${JC[NAME]:-}" out
   printf -v out $"Partly recovered files - %(%Y-%m-%d)T" "$now"
   JC=([ID]="$id" [KIND]=salvage [PARENT]="$parent" [SOURCE]="$s" [DEST]="$d" [SRC_MP]="$BSR_RUN_SMP" [DST_MP]="$BSR_RUN_DMP"
      [SRC_UUID]="${JC[SRC_UUID]:-}" [DST_UUID]="${JC[DST_UUID]:-}" [NAME]="$name" [RETRIES]="$retries" [CREATED]="$now"
      [VERIFY]=basic [LEVEL]="${JC[LEVEL]:-}" [OUT_NAME]="${out//\//-}")
   bsr_job_conf_save "$dir" || { rm -rf -- "$dir"; return 1; }
   JS=([STATE]=pending [PID]="" [BYTES_TOTAL]="$total" [FILES_TOTAL]="${#R[@]}")
   bsr_job_state_save "$dir"
   bsr_rec_image_start "$id" || return 1
   if [ "$json" = 1 ]; then bsr_jo id "$id" dir "$dir"; printf '\n'; return 0; fi
   printf $"Copy started: %s"'\n' "$id"
   if [ "$nowait" = 1 ]; then
      printf $"To follow it: big-storage-rescue --cli status %s --watch"'\n' "$id"
      return 0
   fi
   bsr_job_watch "$id" 1
}

# bsr_sv_holes MAP: the areas of a file that were not read, "START SIZE" in
# bytes, one per line, neighbours joined
bsr_sv_holes() {
   LC_ALL=C awk '
      function hex(s,   i, v) { s = tolower(substr(s, 3)); v = 0
         for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
         return v }
      /^#/ || NF < 2 { next }
      !seen { seen = 1; next }
      $3 != "+" { p = hex($1); n = hex($2)
         if (have && p == start + size) size += n
         else { if (have) printf "%.0f %.0f\n", start, size; start = p; size = n; have = 1 } }
      END { if (have) printf "%.0f %.0f\n", start, size }' "$1" 2>/dev/null
}

# bsr_sv_place WORK_FILE TARGET: moves a finished file to its place, never over
# another file. 1: something is already there
bsr_sv_place() {
   local root parent
   [ -e "$2" ] || [ -L "$2" ] && return 1
   # Folders at the destination may be links copied from the source: the file
   # must land inside the destination, whatever they point to (checked before
   # a folder is made, and again after)
   root="$(readlink -f -- "$BSR_RUN_D")"
   parent="$(readlink -m -- "${2%/*}")"
   [[ $parent == "$root" || $parent == "$root"/* ]] || return 1
   mkdir -p -- "${2%/*}" || return 1
   parent="$(readlink -f -- "${2%/*}")"
   [[ $parent == "$root" || $parent == "$root"/* ]] || return 1
   mv -n -- "$1" "$2" 2>/dev/null
   [ ! -e "$1" ]
}

# bsr_sv_finish DIR STATE [REASON]
bsr_sv_finish() {
   local dir="$1"
   JS[STATE]="$2" JS[REASON]="${3:-}" JS[CURRENT]="" JS[RATE_NOW]=0 JS[ETA]=""
   printf -v "JS[FINISHED]" '%(%s)T' -1
   bsr_sv_sidecar "$dir"
   bsr_job_state_save "$dir"
   bsr_job_report_write "$dir"
}

# The list of what is missing from each file with unreadable areas, next to
# those files, for whoever opens them later
bsr_sv_sidecar() {
   local dir="$1" out="${BSR_RUN_D:-${JC[DEST]}}/${JC[OUT_NAME]}" rel start size bad n
   [ -s "$dir/holes.tsv" ] && [ -d "$out" ] || return 0
   {
      printf '%s\n\n' $"These files were saved with what could be read. The areas listed here could not be read from the damaged drive and hold zeros; the rest of each file is as it was."
      while IFS=$'\t' read -r bad n rel; do
         bsr_human_size "$bad"
         printf '%s\n  %s\n' "$rel" "$(printf $"%s could not be read, at these byte offsets:" "$REPLY")"
         while read -r start size; do
            printf '    %s–%s\n' "$start" "$((start + size - 1))"
         done < "$dir/holes/$n"
         printf '\n'
      done < "$dir/holes.tsv"
   } > "$out/.unreadable.tmp" 2>/dev/null && mv -f -- "$out/.unreadable.tmp" "$out/$(printf $"unreadable areas").txt"
}

# big-storage-rescue --cli __run ID, for a salvage: one file after the other
bsr_sv_supervise() {
   local id="$1" dir s d w rec rest sz mt rel n=-1 r src map outw pid ctl end="" tick last=0 now t0 rc res target bad st
   local base_ok=0 base_bad=0 complete=0 partial=0 lost=0 start_ok
   local -A FINISHED=()
   bsr_job_dir "$id" || return 1
   dir="$REPLY"
   bsr_job_lock "$dir" || return 10
   bsr_job_conf_load "$dir"
   bsr_job_state_load "$dir" || JS=()
   : > "$dir/control"
   mkdir -p -- "$dir/maps" "$dir/holes"
   touch "$dir/done.tsv" "$dir/holes.tsv"
   # N <tab> RESULT <tab> READ <tab> NOT READ, for each file already finished
   while IFS=$'\t' read -r r res sz bad; do
      FINISHED[$r]="$res"
      base_ok=$((base_ok + sz)) base_bad=$((base_bad + bad))
      case "$res" in complete) complete=$((complete + 1)) ;; partial) partial=$((partial + 1)) ;; *) lost=$((lost + 1)) ;; esac
   done < "$dir/done.tsv"
   start_ok="$base_ok" last="$base_ok"
   JS[STATE]=running JS[PID]="$$" JS[REASON]="" JS[ELAPSED_BASE]="${JS[ELAPSED]:-0}"
   bsr_proc_state "$$"; JS[PID_START]="$PROC_START"
   printf -v t0 '%(%s)T' -1
   bsr_job_state_save "$dir"
   trap 'printf "cancel\n" > "$dir/control"' TERM

   bsr_job_locate; rc=$?
   if [ "$rc" -ne 0 ]; then
      [ "$rc" -eq 3 ] && { bsr_sv_finish "$dir" needs-attention source-gone; return 0; }
      bsr_sv_finish "$dir" needs-attention dest-gone
      return 0
   fi
   s="$BSR_RUN_S" d="$BSR_RUN_D"
   w="$d/.big-storage-rescue-salvage-$id"
   mkdir -p -- "$w" 2>/dev/null || { bsr_sv_finish "$dir" needs-attention dest-gone; return 0; }

   while IFS= read -r -u 9 -d '' rec; do
      n=$((n + 1))
      [ -n "${FINISHED[$n]:-}" ] && continue
      sz="${rec%%$'\t'*}" rest="${rec#*$'\t'}"
      mt="${rest%%$'\t'*}" rel="${rest#*$'\t'}"
      src="$s/$rel" map="$dir/maps/$n.map" outw="$w/$n"
      JS[CURRENT]="$rel"
      bsr_job_state_save "$dir"
      # The same file as when it was chosen: a map is only valid for the
      # content it was made from
      bsr_sv_stat "$src"; rc=$?
      res=""
      if [ "$rc" -eq 124 ]; then res=no-answer
      elif [ "$rc" -ne 0 ]; then
         bsr_cp_is_mounted "$BSR_RUN_SMP" || { bsr_sv_finish "$dir" needs-attention source-gone; return 0; }
         res=gone
      else
         read -r _ st r <<< "$REPLY"
         [ "$st $r" = "$sz $mt" ] || { res=changed; rm -f -- "$map" "$map.bak" "$outw"; }
      fi
      # A map without the file it describes would let ddrescue skip areas
      # whose data is gone: both start over
      [ -z "$res" ] && [ -e "$map" ] && [ ! -f "$outw" ] && rm -f -- "$map" "$map.bak"
      if [ -z "$res" ]; then
         # The map is saved every second (by default ddrescue waits 30 s or
         # more): it is what the progress is read from, and what a power cut
         # resumes from
         local args=(-q "--extend-outfile=$sz" --mapfile-interval=1 --no-scrape)
         [ "${JC[RETRIES]:-0}" -gt 0 ] && args=(-q "--extend-outfile=$sz" --mapfile-interval=1 "--retry-passes=${JC[RETRIES]}")
         ionice -c 2 -n 6 nice -n 5 ddrescue "${args[@]}" -- "$src" "$outw" "$map" < /dev/null >> "$dir/ddrescue.out" 2>&1 &
         pid=$! tick=0 end=""
         while kill -0 "$pid" 2>/dev/null; do
            sleep "$BSR_TICK"
            tick=$((tick + 1))
            printf -v now '%(%s)T' -1
            MP_RESCUED=0 MP_BAD=0 MP_TODO=0
            bsr_rec_map_parse "$map"
            JS[BYTES_NOW]=$((base_ok + MP_RESCUED)) JS[BYTES_DONE]=$((base_ok + MP_RESCUED)) JS[BAD_BYTES]=$((base_bad + MP_BAD))
            JS[RATE_NOW]=$(((JS[BYTES_NOW] - last) / BSR_TICK)); [ "${JS[RATE_NOW]}" -lt 0 ] && JS[RATE_NOW]=0
            last="${JS[BYTES_NOW]}"
            JS[ELAPSED]=$((JS[ELAPSED_BASE] + now - t0))
            [ $((now - t0)) -gt 0 ] && JS[RATE_AVG]=$(((JS[BYTES_NOW] - start_ok) / (now - t0)))
            JS[ETA]=""
            r=$((JS[BYTES_TOTAL] - JS[BYTES_NOW] - JS[BAD_BYTES]))
            [ "${JS[RATE_NOW]}" -gt 0 ] && [ "$r" -gt 0 ] && JS[ETA]=$((r / JS[RATE_NOW]))
            ctl=""
            { read -r ctl < "$dir/control"; } 2>/dev/null
            if [ "$ctl" = cancel ] || [ "$ctl" = pause ]; then end="$ctl"
            elif [ $((tick % 5)) -eq 0 ]; then
               bsr_cp_is_mounted "$BSR_RUN_SMP" || end=source-gone
               bsr_cp_is_mounted "$BSR_RUN_DMP" || end=dest-gone
            fi
            if [ -n "$end" ]; then
               JS[STATE]=stopping
               bsr_job_state_save "$dir"
               # ddrescue saves its map on SIGTERM; a read stuck in the driver
               # comes back first
               kill -TERM "$pid" 2>/dev/null
               wait "$pid"
               break
            fi
            bsr_job_state_save "$dir"
         done
         wait "$pid" 2>/dev/null; rc=$?
         if [ -n "$end" ] && bsr_rec_map_parse "$map"; then
            JS[BYTES_NOW]=$((base_ok + MP_RESCUED)) JS[BYTES_DONE]=$((base_ok + MP_RESCUED)) JS[BAD_BYTES]=$((base_bad + MP_BAD))
         fi
         case "$end" in
            pause) bsr_sv_finish "$dir" paused; return 0 ;;
            cancel) bsr_sv_finish "$dir" cancelled; return 0 ;;
            source-gone | dest-gone) bsr_sv_finish "$dir" needs-attention "$end"; return 0 ;;
         esac
         MP_RESCUED=0 MP_BAD=0 MP_TODO=0
         if ! bsr_rec_map_parse "$map" || [ ! -f "$outw" ]; then res=error
         elif [ "$MP_RESCUED" -eq 0 ]; then res=unreadable
         elif [ "$MP_BAD" -eq 0 ] && [ "$MP_TODO" -eq 0 ] && [ "$rc" -eq 0 ]; then res=complete
         else res=partial
         fi
      fi
      case "$res" in
         complete | partial)
            sync -- "$outw" 2>/dev/null
            touch -m -d "@$mt" -- "$outw" 2>/dev/null
            target="$d/$rel"
            # Complete, and nothing there yet: where the copy would have put it
            if [ "$res" != complete ] || ! bsr_sv_place "$outw" "$target"; then
               target="$d/${JC[OUT_NAME]}/$rel"
               if ! bsr_sv_place "$outw" "$target"; then
                  target="${target%/*}/$id-${target##*/}"
                  bsr_sv_place "$outw" "$target" || res=conflict
               fi
            fi
            # Where each file went, relative to the destination (for --cli manifest)
            [ "$res" = conflict ] || printf '%s\0' "${target#"$d"/}" >> "$dir/placed0"
            ;;
         *) rm -f -- "$outw" ;;
      esac
      bad=$((MP_BAD + MP_TODO))
      case "$res" in
         complete) complete=$((complete + 1)) bad=0 ;;
         partial)
            partial=$((partial + 1))
            bsr_sv_holes "$map" > "$dir/holes/$n"
            printf '%s\t%s\t%s\n' "$bad" "$n" "$rel" >> "$dir/holes.tsv"
            ;;
         *) lost=$((lost + 1)) MP_RESCUED=0 bad="$sz" ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "$n" "$res" "${MP_RESCUED:-0}" "$bad" >> "$dir/done.tsv"
      [ "$res" = complete ] || [ "$res" = partial ] || printf '%s\t%s\n' "$(bsr_sv_result_text "$res")" "$rel" >> "$dir/failed.txt"
      base_ok=$((base_ok + ${MP_RESCUED:-0})) base_bad=$((base_bad + bad))
      JS[FILES_DONE]=$((complete + partial)) JS[PARTIAL]="$partial" JS[FAILED]="$lost"
      JS[BYTES_NOW]="$base_ok" JS[BYTES_DONE]="$base_ok" JS[BAD_BYTES]="$base_bad"
      bsr_job_state_save "$dir"
   done 9< "$dir/items0"
   rmdir -- "$w" 2>/dev/null
   JS[FILES_DONE]=$((complete + partial)) JS[PARTIAL]="$partial" JS[FAILED]="$lost"
   if [ "$lost" -gt 0 ]; then bsr_sv_finish "$dir" needs-attention salvage-left
   elif [ "$partial" -gt 0 ]; then bsr_sv_finish "$dir" needs-attention salvage-partial
   else bsr_sv_finish "$dir" completed
   fi
   return 0
}

# Why a file could not be salvaged, for failed.txt and the report
bsr_sv_result_text() {
   case "$1" in
      unreadable) REPLY=$"nothing of it could be read" ;;
      changed) REPLY=$"it changed since the copy, so it was not read again" ;;
      gone) REPLY=$"it is no longer in the source" ;;
      no-answer) REPLY=$"the drive did not answer about it in time" ;;
      conflict) REPLY=$"a file with its name is already at the destination; it was kept" ;;
      *) REPLY=$"GNU ddrescue stopped with an error; see the log" ;;
   esac
   printf '%s' "$REPLY"
}

# The part of a report about a salvage
bsr_sv_report_text() {
   local dir="$1" n
   bsr_doc_kv $"Destination" "${JC[DEST]}"
   bsr_doc_kv $"Files read completely" "$(( ${JS[FILES_DONE]:-0} - ${JS[PARTIAL]:-0} ))"
   bsr_doc_kv $"Files saved with unreadable areas" "${JS[PARTIAL]:-0}"
   bsr_human_size "${JS[BYTES_DONE]:-0}"; bsr_doc_kv $"Data read" "$REPLY"
   bsr_human_size "${JS[BAD_BYTES]:-0}"; bsr_doc_kv $"Could not be read" "$REPLY"
   bsr_fmt_time "${JS[ELAPSED]:-0}"; bsr_doc_kv $"Elapsed" "$REPLY"
   [ "${JS[PARTIAL]:-0}" -gt 0 ] && bsr_doc_kv $"Files with unreadable areas are in" "${JC[DEST]}/${JC[OUT_NAME]}"
   bsr_ui_show info ""
   n="${JS[FAILED]:-0}"
   if [ "$n" -gt 0 ] && [ -s "$dir/failed.txt" ]; then
      printf '\n%s\n' $"Not saved:"
      head -n 50 -- "$dir/failed.txt" | bsr_printable_lines
   fi
   printf '\n%s %s\n' $"Log:" "$dir/ddrescue.out"
}
