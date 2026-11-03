# 16 — Migration of the state of Big-Mount 2.x

`migrate.sh`, run quietly the first time `--gui` or `--cli` starts (one test
of two folders afterwards), or explicitly with
`big-storage-rescue --migrate-state [--dry-run]`.

| Big-Mount 2.x | Big Storage Rescue | How |
| --- | --- | --- |
| `~/.local/state/big-mount/jobs/ID/` | `~/.local/state/big-storage-rescue/jobs/ID/` | copied; the original stays as the backup |
| `~/.config/big-mount/gui.ini` | `~/.config/big-storage-rescue/gui.ini` | copied only when there is none |
| `~/.config/autostart/big-mount-notifier.desktop` (on) | `…/big-storage-rescue-notifier.desktop` | created from this package's entry; an entry turned off (`Hidden=true`) stays off |
| `~/.local/state/big-mount/notified` | — | per boot only, not needed |

## Rules

- **Never moves, never changes** the data of Big-Mount: the job is copied
  (`cp -a`) under `.migrating-ID`, completed, then renamed to `ID` in one step.
  A power cut leaves either nothing or a whole job; a `.migrating-ID` left
  behind is removed and redone next time. The only file added to the original
  is a note, `MOVED-TO-big-storage-rescue`.
- **Never writes over** a job that exists here.
- **Validates** before copying: the folder name is a job ID, `job.conf` is a
  regular file of the user that names the same ID and a known kind, and it was
  not brought over before. Anything else stays in Big-Mount and is reported.
- **Never touches a running job**: if the supervisor of Big-Mount holds the
  lock of the job, it is skipped (exit 3) and the migration is not marked done,
  so it is tried again the next time. Nothing is stopped or interrupted.
- **Resumable**: a copied job records `WORK_PREFIX=.big-mount` (its folders in
  the destination keep their names, so what rsync already wrote is used) and
  `MIGRATED_FROM=<original folder>`; the supervisor also takes the lock of the
  original, and `resume` refuses (exit 10) while Big-Mount runs that job.
  ddrescue mapfiles are next to the images, at the destination: nothing to
  move, and the image job resumes from them.
- **Idempotent**: the first complete run writes
  `~/.local/state/big-storage-rescue/migrated-from-big-mount`; later starts
  only look at it. `--migrate-state` can always be run again; `migration.log`
  records every run.
- **Nothing to migrate, nothing created**: without any Big-Mount state no folder
  or file is written.

## Validation

`tests/migrate-tests.sh` (41 checks, scratch folders only):

- dry run writes nothing; a job held by a lock is left alone, named, and the
  migration stays pending; invalid folders are reported and left in place;
- copied jobs are complete, private (700), without the old lock, with
  `WORK_PREFIX` and `MIGRATED_FROM`; the originals are byte-for-byte unchanged;
- a second run brings over the job that ended, replaces an interrupted
  `.migrating-ID`, never writes over an existing job or preference;
- the notifier follows the choice made in Big-Mount;
- **a real copy**, started, paused, turned into a Big-Mount job (folder and
  `.big-mount-tmp-ID` in the destination), is found by `--cli jobs` (migrated on
  start), refused while its Big-Mount lock is held, then resumed and completed
  here: every file byte for byte, no `.big-storage-rescue-*` folder created,
  the `.big-mount-tmp-ID` folder cleaned at the end.

On the development machine, on a **copy** of the real state (four jobs of
Big-Mount 2.6: three copies and one image): all four were brought over and
listed with their states by `--cli jobs`. On the real state, read-only
(`--dry-run`): three would be brought over, and the image job that was running
during this work was reported as *still running in Big-Mount* (exit 3).
