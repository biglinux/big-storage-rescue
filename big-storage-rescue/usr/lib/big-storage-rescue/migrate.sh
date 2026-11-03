# shellcheck shell=bash
# shellcheck disable=SC2015  # "check && check || refuse" on purpose: refuse returns
#
# Big Storage Rescue: bringing over what Big-Mount 2.x left in the home folder,
# where its drive manager lived before this package existed:
#
#   ~/.local/state/big-mount/jobs/ID   copies, disk images and searches, which
#                                      may be paused or interrupted
#   ~/.config/big-mount/gui.ini        the preferences of the window
#   ~/.config/autostart/big-mount-notifier.desktop
#                                      the read-only notifier, when it was on
#
# Nothing of Big-Mount is changed or removed: every job is copied to
# ~/.local/state/big-storage-rescue/jobs/ID, and the original stays where it was
# as the backup (with a note, MOVED-TO-big-storage-rescue, for a person who
# looks there). The copy is made under a temporary name and renamed when it
# is complete, so a power cut leaves either nothing or a whole job; a job that
# already exists here is never written over. A job whose supervisor is still
# running is left alone, and the migration is tried again next time.
#
# A copy resumes with what it already wrote: its folders in the destination
# keep the names Big-Mount gave them (WORK_PREFIX=.big-mount), and the
# supervisor also takes the lock of the original job (MIGRATED_FROM), so a
# Big-Mount from before the split, if still installed, cannot resume it too.
#
# When everything is done, ~/.local/state/big-storage-rescue/migrated-from-big-mount
# records it, and later starts only look at that file. A job that could not be
# copied (a full disk) is tried again on the next start; one that is not a
# valid job never will be, and does not hold the mark back.
#
# Exit codes: 0 done (or nothing to do), 1 some jobs could not be brought
# over (they stay in place), 3 some jobs are running in Big-Mount: try again
# when they end.

# bsr_migrate_paths: where things are (MG_*)
bsr_migrate_paths() {
   local state="${XDG_STATE_HOME:-$HOME/.local/state}" conf="${XDG_CONFIG_HOME:-$HOME/.config}"
   MG_OLD_JOBS="$state/big-mount/jobs"
   MG_NEW_STATE="$state/big-storage-rescue"
   MG_NEW_JOBS="$MG_NEW_STATE/jobs"
   MG_DONE="$MG_NEW_STATE/migrated-from-big-mount"
   MG_LOG="$MG_NEW_STATE/migration.log"
   MG_OLD_CONF="$conf/big-mount"
   MG_NEW_CONF="$conf/big-storage-rescue"
   MG_OLD_AUTOSTART="$conf/autostart/big-mount-notifier.desktop"
   MG_NEW_AUTOSTART="$conf/autostart/big-storage-rescue-notifier.desktop"
   MG_TEMPLATE="${BSR_LIB_DIR%/lib/big-storage-rescue}/share/big-storage-rescue/big-storage-rescue-notifier.desktop"
}

# bsr_migrate_job_valid DIR: a job of Big-Mount that can be resumed here.
# job.conf is read as data, as drive-copy.sh reads it.
bsr_migrate_job_valid() {
   local dir="$1" id="${1##*/}" l k v kind="" seen_id=""
   [[ $id =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]] || { REPLY=$"not a job folder"; return 1; }
   [ -f "$dir/job.conf" ] && [ ! -L "$dir/job.conf" ] || { REPLY=$"job.conf is missing"; return 1; }
   [ -O "$dir" ] || { REPLY=$"it does not belong to you"; return 1; }
   while IFS= read -r l; do
      k="${l%%=*}" v="${l#*=}"
      [ "$k" != "$l" ] || continue
      case "$k" in
         ID) seen_id="$v" ;;
         KIND) kind="$v" ;;
         WORK_PREFIX | MIGRATED_FROM) REPLY=$"it was already brought over once"; return 1 ;;
      esac
   done < "$dir/job.conf"
   [ "$seen_id" = "$id" ] || { REPLY=$"job.conf names another job"; return 1; }
   case "$kind" in
      "" | copy | image | scan | carve) ;;
      *) printf -v REPLY $"unknown kind of job: %s" "$kind"; return 1 ;;
   esac
   return 0
}

# bsr_migrate_job_active DIR: its supervisor (bigmount --drive __run) is running
bsr_migrate_job_active() {
   [ -e "$1/lock" ] || return 1
   ! flock -n "$1/lock" true 2>/dev/null
}

# bsr_migrate_job DIR DRY: copy one job (MG_RESULT: moved | exists | active |
# invalid | failed, MG_WHY for a person)
bsr_migrate_job() {
   local old="$1" dry="$2" id="${1##*/}" tmp new
   new="$MG_NEW_JOBS/$id" tmp="$MG_NEW_JOBS/.migrating-$id"
   MG_WHY=""
   if [ -e "$new" ]; then MG_RESULT=exists; return 0; fi
   if ! bsr_migrate_job_valid "$old"; then MG_RESULT=invalid MG_WHY="$REPLY"; return 0; fi
   if bsr_migrate_job_active "$old"; then MG_RESULT=active; return 0; fi
   if [ "$dry" = 1 ]; then MG_RESULT=moved; return 0; fi
   # A copy left by an interrupted run is ours and incomplete: start over
   rm -rf -- "$tmp"
   if ! cp -a -- "$old" "$tmp" 2>/dev/null; then
      rm -rf -- "$tmp"
      MG_RESULT=failed MG_WHY=$"copying it failed (is the disk full?)"
      return 0
   fi
   rm -f -- "$tmp/lock" "$tmp/MOVED-TO-big-storage-rescue"
   if ! printf 'WORK_PREFIX=.big-mount\nMIGRATED_FROM=%s\n' "$old" >> "$tmp/job.conf" || ! mv -T -- "$tmp" "$new" 2>/dev/null; then
      rm -rf -- "$tmp"
      MG_RESULT=failed MG_WHY=$"it could not be written"
      return 0
   fi
   printf $"This job was brought over to Big Storage Rescue on %s: %s\nThis folder is kept as a backup; Big Storage Rescue resumes it from there.\n" \
      "$(date -Is)" "$new" > "$old/MOVED-TO-big-storage-rescue" 2>/dev/null
   MG_RESULT=moved
}

# bsr_migrate_run MODE: MODE auto (on start: quiet, once), run or dry-run
bsr_migrate_run() {
   local mode="$1" dry=0 d n_moved=0 n_active=0 n_bad=0 n_retry=0 lines=() rc=0
   [ "$mode" = "dry-run" ] && dry=1
   bsr_migrate_paths
   MG_LINES=() MG_MOVED=0
   [ "$mode" = auto ] && [ -e "$MG_DONE" ] && return 0
   # Nothing of Big-Mount: nothing is created either
   [ -d "$MG_OLD_JOBS" ] || [ -f "$MG_OLD_CONF/gui.ini" ] || [ -f "$MG_OLD_AUTOSTART" ] || return 0
   if [ "$dry" = 0 ]; then
      mkdir -p -- "$MG_NEW_STATE" && { [ -d "$MG_NEW_JOBS" ] || mkdir -m 0700 -- "$MG_NEW_JOBS"; } || return 1
      # One migration at a time: the window and a terminal may start together.
      # Released on the way out: the same process goes on to the window, and
      # every other start would wait for it
      exec {MG_LOCK_FD}>"$MG_NEW_STATE/migration.lock" || return 1
      flock -w 30 "$MG_LOCK_FD" || { exec {MG_LOCK_FD}>&-; return 1; }
      if [ "$mode" = auto ] && [ -e "$MG_DONE" ]; then exec {MG_LOCK_FD}>&-; return 0; fi
   fi
   if [ -d "$MG_OLD_JOBS" ]; then
      for d in "$MG_OLD_JOBS"/*; do
         [ -d "$d" ] && [ ! -L "$d" ] || continue
         bsr_migrate_job "$d" "$dry"
         case "$MG_RESULT" in
            moved) n_moved=$((n_moved + 1)); lines+=("moved ${d##*/}") ;;
            exists) lines+=("exists ${d##*/}") ;;
            active) n_active=$((n_active + 1)); lines+=("active ${d##*/}") ;;
            *)
               n_bad=$((n_bad + 1)); lines+=("$MG_RESULT ${d##*/} $MG_WHY")
               [ "$MG_RESULT" = failed ] && n_retry=$((n_retry + 1))
               ;;
         esac
      done
   fi
   # The preferences of the window, when there are none here yet
   if [ -f "$MG_OLD_CONF/gui.ini" ] && [ ! -e "$MG_NEW_CONF/gui.ini" ]; then
      lines+=("settings gui.ini")
      if [ "$dry" = 0 ]; then
         mkdir -p -- "$MG_NEW_CONF" && cp -p -- "$MG_OLD_CONF/gui.ini" "$MG_NEW_CONF/gui.ini.tmp" &&
            mv -f -- "$MG_NEW_CONF/gui.ini.tmp" "$MG_NEW_CONF/gui.ini"
      fi
   fi
   # The notifier the person turned on in Big-Mount goes on here (the
   # Big-Mount entry is left: the new Big-Mount ignores it)
   if [ -f "$MG_OLD_AUTOSTART" ] && [ ! -e "$MG_NEW_AUTOSTART" ] && [ -r "$MG_TEMPLATE" ] &&
      ! grep -qx -e 'Hidden=true' -e 'X-GNOME-Autostart-enabled=false' -- "$MG_OLD_AUTOSTART"; then
      lines+=("notifier on")
      if [ "$dry" = 0 ]; then
         mkdir -p -- "${MG_NEW_AUTOSTART%/*}" && cp -- "$MG_TEMPLATE" "$MG_NEW_AUTOSTART.tmp" &&
            mv -f -- "$MG_NEW_AUTOSTART.tmp" "$MG_NEW_AUTOSTART"
      fi
   fi

   if [ "$dry" = 0 ] && [ "${#lines[@]}" -gt 0 ]; then
      { printf '# %s\n' "$(date -Is)"; printf '%s\n' "${lines[@]}"; } >> "$MG_LOG"
   fi
   if [ "$n_active" -gt 0 ]; then rc=3
   elif [ "$n_bad" -gt 0 ]; then rc=1
   fi
   # Done for good when nothing is left to try again: invalid jobs stay where
   # they are, and are named in the log and by --migrate-state; a running job
   # or one that failed to copy is tried again
   if [ "$dry" = 0 ] && [ "$n_active" -eq 0 ] && [ "$n_retry" -eq 0 ] && [ ! -e "$MG_DONE" ]; then
      { printf '# %s\n' "$(date -Is)"; [ "${#lines[@]}" -gt 0 ] && printf '%s\n' "${lines[@]}"; } > "$MG_DONE"
   fi
   MG_LINES=("${lines[@]}") MG_MOVED="$n_moved"
   [ "$dry" = 0 ] && exec {MG_LOCK_FD}>&-
   return "$rc"
}

# big-storage-rescue --migrate-state [--dry-run]: the same, with a report
bsr_migrate_cmd() {
   local mode=run a l rc
   for a in "$@"; do
      case "$a" in
         --dry-run) mode="dry-run" ;;
         *) printf $"big-storage-rescue: unknown option '%s' (see big-storage-rescue --help)"'\n' "$a" >&2; return 2 ;;
      esac
   done
   bsr_migrate_run "$mode"; rc=$?
   if [ "${#MG_LINES[@]}" -eq 0 ]; then
      printf '%s\n' $"Nothing of Big-Mount 2.x to bring over."
      return "$rc"
   fi
   [ "$mode" = dry-run ] && printf '%s\n' $"Nothing is changed (--dry-run). It would do this:"
   for l in "${MG_LINES[@]}"; do
      case "$l" in
         "moved "*) printf $"Job %s: brought over"'\n' "${l#moved }" ;;
         "exists "*) printf $"Job %s: already here, left as it is"'\n' "${l#exists }" ;;
         "active "*) printf $"Job %s: still running in Big-Mount; it is brought over when it ends"'\n' "${l#active }" ;;
         "settings "*) printf '%s\n' $"Preferences of the window: brought over" ;;
         "notifier "*) printf '%s\n' $"Read-only notifier: on, as it was in Big-Mount" ;;
         *)
            l="${l#* }"
            printf $"Job %s: left in Big-Mount (%s)"'\n' "${l%% *}" "${l#* }"
            ;;
      esac
   done
   [ "${MG_MOVED:-0}" -gt 0 ] && [ "$mode" != dry-run ] &&
      printf $"The originals stay in %s as a backup."'\n' "$MG_OLD_JOBS"
   return "$rc"
}
