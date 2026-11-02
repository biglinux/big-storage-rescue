#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets and helpers called through check() and traps
# What Big-Mount 2.x left in the home folder is brought over (migrate.sh):
# jobs are copied, never moved or changed; a running one is left alone; a job
# that exists here is never written over; an interrupted migration is redone;
# and a paused copy of Big-Mount resumes here with what it already wrote.
#
# Everything happens in scratch folders (XDG_STATE_HOME, XDG_CONFIG_HOME): the
# real home folder is never read. The copy goes from /var/tmp to /dev/shm.
#
# Usage: tests/migrate-tests.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
B="$REPO/big-storage-rescue/usr/bin/big-storage-rescue"
PASS=0 FAIL=0 FAILED=()
G=$'\033[32m' R=$'\033[31m' N=$'\033[0m'

check() {
    local desc="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); echo "  ${G}✓${N} $desc"
    else FAIL=$((FAIL + 1)); FAILED+=("$desc"); echo "  ${R}✗${N} $desc"; fi
}
eq() { [ "$1" = "$2" ] || { printf '      got: [%s]\n expected: [%s]\n' "$1" "$2"; return 1; }; }
begin() { echo "— $1"; }

WORK="$(mktemp -d)"
SRC="$(mktemp -d -p /var/tmp bsr-mig-src-XXXXXX)"
DST="/dev/shm/bsr-mig-dst-$$"
cleanup() { rm -rf "$WORK" "$SRC" "$DST"; }
# Big-Mount running a job: its supervisor holds the lock of the job folder
hold() { exec {HOLD}<"$1"; flock -n "$HOLD"; }
release() { exec {HOLD}<&-; }
trap cleanup EXIT
export XDG_STATE_HOME="$WORK/state" XDG_CONFIG_HOME="$WORK/config" XDG_RUNTIME_DIR="$WORK/run" LANGUAGE=C
mkdir -p "$XDG_RUNTIME_DIR"
OLD="$XDG_STATE_HOME/big-mount/jobs" NEW="$XDG_STATE_HOME/big-storage-rescue/jobs"

# A job of Big-Mount as it leaves it on disk
old_job() { # ID KIND STATE
    mkdir -p "$OLD/$1"
    printf 'ID=%s\nKIND=%s\nSOURCE=/x\nDEST=/y\n' "$1" "$2" > "$OLD/$1/job.conf"
    printf 'STATE=%s\nBYTES_DONE=10\n' "$3" > "$OLD/$1/state.env"
    : > "$OLD/$1/lock"
    printf 'log of %s\n' "$1" > "$OLD/$1/events.log"
}
tree_sum() { (cd "$1" && find . -path ./\*/MOVED-TO-big-storage-rescue -prune -o -type f -print0 | sort -z | xargs -0 sha1sum); }

begin "nothing of Big-Mount"
out="$("$B" --migrate-state)"; rc=$?
check "nothing to bring over: said, exit 0" eq "$rc:$out" "0:Nothing of Big-Mount 2.x to bring over."

begin "a dry run changes nothing"
old_job 20261031-104503-7b34 copy completed
old_job 20261031-121059-14d9 image paused
old_job 20261031-162448-0e7b carve completed
mkdir -p "$OLD/20261101-000000-bad0"; printf 'ID=20261101-000000-ffff\n' > "$OLD/20261101-000000-bad0/job.conf"
mkdir -p "$OLD/not-a-job"
mkdir -p "$XDG_CONFIG_HOME/big-mount" "$XDG_CONFIG_HOME/autostart"
printf '[welcome]\nshow=false\n' > "$XDG_CONFIG_HOME/big-mount/gui.ini"
printf '[Desktop Entry]\nExec=/usr/bin/bigmount --notifier\n' > "$XDG_CONFIG_HOME/autostart/big-mount-notifier.desktop"
before="$(tree_sum "$XDG_STATE_HOME/big-mount")"
"$B" --migrate-state --dry-run > "$WORK/dry"; rc=$?
check "dry run: exit 1, one job cannot be brought over" eq "$rc" 1
check "  ... it says what it would do" grep -q '^Job 20261031-104503-7b34: brought over$' "$WORK/dry"
check "  ... nothing was written" test ! -e "$XDG_STATE_HOME/big-storage-rescue"
check "  ... no setting either" test ! -e "$XDG_CONFIG_HOME/big-storage-rescue"

begin "a job that is running in Big-Mount is left alone"
hold "$OLD/20261031-121059-14d9/lock"
"$B" --migrate-state > "$WORK/run1"; rc=$?
check "exit 3: try again later" eq "$rc" 3
check "  ... the running one is not copied" test ! -e "$NEW/20261031-121059-14d9"
check "  ... and it is named" grep -q '^Job 20261031-121059-14d9: still running in Big-Mount' "$WORK/run1"
check "  ... the others are" bash -c '[ -f "$1/20261031-104503-7b34/job.conf" ] && [ -f "$1/20261031-162448-0e7b/job.conf" ]' _ "$NEW"
check "  ... not done for good: no mark" test ! -e "$XDG_STATE_HOME/big-storage-rescue/migrated-from-big-mount"
check "  ... a job that names another one is left in Big-Mount" bash -c '[ ! -e "$1/20261101-000000-bad0" ] && grep -q "20261101-000000-bad0: left in Big-Mount (job.conf names another job)" "$2"' _ "$NEW" "$WORK/run1"
check "  ... a folder that is not a job too" test ! -e "$NEW/not-a-job"
release

begin "what was copied"
check "the job and its files" eq "$(cat "$NEW/20261031-104503-7b34/events.log")" "log of 20261031-104503-7b34"
check "  ... it keeps the names of its folders in the destination" grep -qx 'WORK_PREFIX=.big-mount' "$NEW/20261031-104503-7b34/job.conf"
check "  ... and knows where it came from" grep -qx "MIGRATED_FROM=$OLD/20261031-104503-7b34" "$NEW/20261031-104503-7b34/job.conf"
check "  ... the lock of Big-Mount is not carried over" test ! -e "$NEW/20261031-104503-7b34/lock"
check "  ... private" eq "$(stat -c %a "$NEW")" 700
check "the originals are untouched" eq "$(tree_sum "$XDG_STATE_HOME/big-mount")" "$before"
check "  ... with a note for a person who looks there" test -s "$OLD/20261031-104503-7b34/MOVED-TO-big-storage-rescue"
check "the preferences of the window" grep -qx 'show=false' "$XDG_CONFIG_HOME/big-storage-rescue/gui.ini"
check "the notifier that was on stays on" grep -q -- '--notifier' "$XDG_CONFIG_HOME/autostart/big-storage-rescue-notifier.desktop"
check "  ... from the entry of this package" grep -q '^Exec=/usr/bin/big-storage-rescue --notifier$' "$XDG_CONFIG_HOME/autostart/big-storage-rescue-notifier.desktop"

begin "again, when the running job ended"
printf 'mine\n' > "$NEW/20261031-104503-7b34/events.log"
mkdir -p "$NEW/.migrating-20261031-121059-14d9"; printf 'half\n' > "$NEW/.migrating-20261031-121059-14d9/job.conf"
"$B" --migrate-state > "$WORK/run2"; rc=$?
check "exit 1: only the bad job is left behind" eq "$rc" 1
check "  ... the job that ended is brought over" grep -qx 'KIND=image' "$NEW/20261031-121059-14d9/job.conf"
check "  ... over what an interrupted migration had left" bash -c '! grep -q half "$1" && [ ! -e "$2" ]' _ "$NEW/20261031-121059-14d9/job.conf" "$NEW/.migrating-20261031-121059-14d9"
check "  ... a job that is already here is never written over" eq "$(cat "$NEW/20261031-104503-7b34/events.log")" mine
check "  ... done for good now" test -e "$XDG_STATE_HOME/big-storage-rescue/migrated-from-big-mount"
printf '[welcome]\nshow=true\n' > "$XDG_CONFIG_HOME/big-storage-rescue/gui.ini"
"$B" --migrate-state > /dev/null
check "  ... the preferences of this program are never replaced" grep -qx 'show=true' "$XDG_CONFIG_HOME/big-storage-rescue/gui.ini"
check "  ... and the log says what happened" grep -q '^moved 20261031-121059-14d9$' "$XDG_STATE_HOME/big-storage-rescue/migration.log"

begin "a notifier that was turned off stays off"
rm -rf "$XDG_CONFIG_HOME/autostart/big-storage-rescue-notifier.desktop" "$XDG_STATE_HOME/big-storage-rescue/migrated-from-big-mount"
printf '[Desktop Entry]\nHidden=true\n' > "$XDG_CONFIG_HOME/autostart/big-mount-notifier.desktop"
"$B" --migrate-state > /dev/null
check "no entry is created" test ! -e "$XDG_CONFIG_HOME/autostart/big-storage-rescue-notifier.desktop"

begin "a paused copy of Big-Mount resumes here"
rm -rf "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
mkdir -p "$SRC/fotos"
head -c 600000 /dev/urandom > "$SRC/fotos/grande.bin"
for i in 1 2 3 4 5; do printf 'arquivo %s\n' "$i" > "$SRC/fotos/f$i.txt"; done
if command -v rsync >/dev/null && [ "$(findmnt -n -o SOURCE -T "$SRC")" != "$(findmnt -n -o SOURCE -T /dev/shm)" ]; then
    status() { "$B" --cli status "$1" --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["state"])'; }
    wait_state() { local i s; for ((i = 0; i < 300; i++)); do s="$(status "$1")"; [[ " $2 " == *" $s "* ]] && return 0; sleep 0.1; done; echo "      state: $s"; return 1; }
    id="$("$B" --cli copy --source "$SRC" --destination "$DST" --bwlimit 50 --scan no --no-wait --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    check "a slow copy starts" wait_state "$id" running
    sleep 1
    "$B" --cli pause "$id" > /dev/null 2>&1
    check "  ... and is paused" wait_state "$id" paused
    # Now it becomes a job of Big-Mount 2.x: its folder, and its names in the destination
    mkdir -p "$OLD"
    mv "$NEW/$id" "$OLD/$id"
    rm -rf "$XDG_STATE_HOME/big-storage-rescue"
    for k in tmp backup; do [ -d "$DST/.big-storage-rescue-$k-$id" ] && mv "$DST/.big-storage-rescue-$k-$id" "$DST/.big-mount-$k-$id"; done
    mkdir -p "$DST/.big-mount-tmp-$id"
    "$B" --cli jobs --json > "$WORK/jobs.json"
    check "the window and the terminal find it: brought over on start" grep -q "\"id\":\"$id\"" "$WORK/jobs.json"
    check "  ... still paused" eq "$(status "$id")" paused
    hold "$OLD/$id/lock"
    "$B" --cli resume "$id" --no-wait > "$WORK/resume" 2>&1; rc=$?
    check "while Big-Mount runs it, it is not resumed here (exit 10)" eq "$rc" 10
    check "  ... and the person is told why" grep -q 'Big-Mount is running this job' "$WORK/resume"
    release
    sed -i '/^BWLIMIT=/d' "$NEW/$id/job.conf"
    "$B" --cli resume "$id" --no-wait > /dev/null 2>&1; rc=$?
    check "resumed here (exit $rc)" eq "$rc" 0
    check "  ... and completed" wait_state "$id" "completed"
    check "  ... every file is in the destination, byte for byte" diff -r "$SRC" "$DST"
    check "  ... with the folders of Big-Mount, not new ones" bash -c '! compgen -G "$1/.big-storage-rescue-*" >/dev/null' _ "$DST"
    check "  ... which are cleaned up at the end" test ! -e "$DST/.big-mount-tmp-$id"
else
    echo "  (skipped: rsync, or /var/tmp and /dev/shm on one filesystem)"
fi

echo ""
echo "========================================="
echo "migrate result: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
