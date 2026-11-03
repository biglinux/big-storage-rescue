# 09 — Copying, progress, pause and resume

The copy engine (`drive-copy.sh`) is the one of Big-Mount 2.6, unchanged in
behaviour; its reasons are in `big-mount-history/16-drive-copy-engine.md` and
the field report it came from in `big-mount-history/12-field-report.md`.

## A job

```
~/.local/state/big-storage-rescue/jobs/ID/      (mode 700; ID = YYYYmmdd-HHMMSS-xxxx)
  job.conf      what was asked: source, destination, their UUIDs, options
  state.env     how far it got (replaced atomically)
  events.log    rsync log: the record of what was copied
  rsync.out     errors, deferred.txt, failed.txt, differences.txt
  report.txt, report.json
  lock          held by the supervisor while it runs
```

The supervisor (`--cli __run ID`) runs `rsync -rlt -8 --one-file-system
--fsync --temp-dir=…` with the selection, and updates `state.env` once a second:
current file, files and bytes done, rate now and on average, elapsed, ETA, read
failures, files set aside. The window and `--cli status ID --watch` read that
file; they never talk to rsync.

## Progress that is true

A total is measured first (`--scan auto`: a dry run, metadata only), except on
a drive at risk: then there is no percentage, only what was copied, rather than
a scan that wears the disk.

## Pause and resume

| Kind | Pause | Resume |
| --- | --- | --- |
| copy | yes: rsync is stopped between files; files already renamed are complete | yes, also after a power cut; the log is the record |
| image (ddrescue) | yes: stopped through its stop file | yes, from the mapfile |
| salvage | yes: ddrescue stopped with SIGTERM, which saves its map | yes, from the map of the file it was on: what was read is not read again |
| scan, carve | no (the window shows no pause button) | they can be started again |

`pausable` in the JSON of a job tells the window whether to show the button.
A job whose supervisor is gone (power cut, kill) is *interrupted* and can be
resumed. Resuming relocates source and destination by UUID: the drive may come
back under another name or mount point.

## Safety rules

Refused: destination inside the source or the reverse (real paths), same
filesystem, read-only destination, items outside the source, not enough room
for a measured total. Refused unless allowed: the same physical disk (through
partitions, LUKS, LVM), a destination on a drive with critical alerts, a
source at risk mounted with writing. Existing files are kept by default
(`--on-conflict skip|backup|overwrite`). Nothing is ever deleted at either end.
A file that stops advancing for 90 s is set aside and retried at the end on
request; more than 100 set aside stops the job (the drive is getting worse).

## What a copy left out: salvage

A copy is file by file on purpose. A file with its final name is complete,
even after a power cut. The price is that a file with one bad sector, or a
large file that was interrupted, is not there at all.
`--cli salvage COPY_ID` (or *Save what can be read…* on the page of the
copy) reads those files again with GNU ddrescue, block by block, with a map
each, and saves what can be read. A file with holes never goes under the
name of a good file. Details and the options that were rejected
(`--append`, `--partial-dir`): [21](21-world-class-progress.md).

## Verification

`--verify basic` (rsync's own checks), `metadata` (size and time compared
again), `full` (checksums: reads the source again, so not advised on a failing
drive). The result is `ok`, `differences` (listed) or `failed`.

## Jobs of Big-Mount 2.x

A job brought over by `migrate.sh` keeps `WORK_PREFIX=.big-mount`, so its
folders in the destination are still `.big-mount-tmp-ID` and
`.big-mount-backup-ID`; new jobs use `.big-storage-rescue-…`. Both are always
excluded from a copy. See 16-migration-validation.md.
