# 00 — Audit of the state found (2026-11-03)

Branch `feature/world-class-recovery`, started from `146bde8` (the merge of the
Big-Mount split into `ruscher/big-storage-rescue` `main`). This audit came
before any change. What was done about each point is in
[21-world-class-progress.md](21-world-class-progress.md). The comparison
with other tools is in [20-global-benchmark.md](20-global-benchmark.md).

## Method

- Read the code: the engine, the window, the helpers and the tests.
- Read docs 01 to 18 and the README.
- Ran every suite on scratch files.
- Two independent reviews ran in parallel: a security review of the
  privileged paths, and a survey of the reference tools (doc 20).
- Nothing touched a real disk. The development machine was doing a real
  rescue at the time (a Big-Mount 2.6 copy, a ddrescue image and a stuck
  FUSE mount). It was left alone, and nothing was installed over it.

## Architecture as found

| Part | What it is | Size |
| --- | --- | --- |
| Engine | bash modules under `usr/lib/big-storage-rescue`, loaded with `bsr_load`; every operation is `big-storage-rescue --cli COMMAND [--json]` | ~9 400 lines |
| Window | Python, GTK 4 and libadwaita; talks to the engine only through `--cli … --json` (`gui/engine.py`), never to the tools | ~4 200 lines |
| Privileged | `bsr-drive-helper` and `bsr-holders` through pkexec (two polkit actions, `auth_admin_keep`), UDisks2 for mounting | 240 lines |
| Jobs | detached supervisors (`--cli __run ID`) with `job.conf` and `state.env` in `~/.local/state/big-storage-rescue/jobs`, resumable after a power cut | — |
| Tests | lib (267), drive (312), migrate (41), i18n (37), package (102), gui (165, Broadway), gui-e2e (7); ShellCheck and ruff clean | — |

Having one engine for the window and the terminal is worth keeping:
- the window cannot show something the engine does not say;
- every feature can be tested without a display;
- everything works over SSH.

No change of architecture was justified.

## What exists already, so it is not duplicated

- Drive list with a health grade:
  - SMART and NVMe data;
  - the kernel log of this boot and of earlier boots;
  - Btrfs and ext4 error counters;
  - the running-system checks.
- Diagnosis of read-only devices, busy processes and safe removal.
- Copy with rsync:
  - a temp folder, then rename and fsync;
  - stuck files set aside;
  - per-file resume;
  - three verify levels.
- Disk image with GNU ddrescue through the helper:
  - mapfile with `.bak`;
  - `--idirect --no-scrape`;
  - optional retries.
- TestDisk partition analysis, read-only.
- PhotoRec carving, with an mmap index browser that handles millions of rows and shows thumbnails.
- Destination checks:
  - not the same physical disk (through LUKS and LVM);
  - not inside the source;
  - enough room.
- Diskseq identity checks.
- Reports, anonymized on request.
- `--doctor`.
- Big-Mount 2.x migration.
- pt_BR translation.

## Documented limitations, investigated

| Limitation (README) | Finding | Verdict |
| --- | --- | --- |
| A large file interrupted starts over | rsync copies to a temp file. On pause it is stopped with SIGTERM and removes that file. Per-file resume is by design: "a file with its final name is complete" holds after a power cut. | Real. The safe fix is not `--append`; see doc 21 (salvage) |
| A partly readable file is not saved | rsync gives up on the whole file at the first read error | Real; fixed by salvage (doc 21) |
| XFS/Btrfs with an unclean log cannot be mounted without replay | UDisks2 refuses `norecovery`/`rescue=` options for users | Real, open. Path: image, read-only loop, then `norecovery`/`rescue=` on the loop (doc 20, P1) |
| `cancel` waits for a blocked read | A read stuck in the driver is uninterruptible (D state). The engine never uses SIGKILL, on purpose: a killed rsync leaves its temp file, a killed ddrescue a stale map. The window says "Stopping: waiting for the disk to answer". | Not a bug: inherent |
| Owners are not preserved | Copies run as the user | By design (no root copy) |
| FAT32 cannot hold 4 GiB | Warned before a copy | By design; a salvage onto FAT32 fails for those files too (reported per file) |
| LVM, RAID, SD, eMMC not validated on hardware | Fixtures only | Still true: no such hardware in this work |
| Automount by Dolphin before protection | UDisks2 and desktop policy | Unchanged, outside the program |
| Accessibility | Roles, labels and focus are tested on Broadway (class `Accessibility`); no screen reader session | Partly validated |
| Distributions | Arch/Manjaro/BigLinux only | Unchanged; no other package claimed |

## Findings that were not documented

| # | Finding | Evidence | Severity |
| --- | --- | --- | --- |
| 1 | The helper's `image` verb did not refuse the drives of the running system. With `auth_admin_keep`, any process of the session could copy the whole system disk, open LUKS volumes included, into a file of the user for 5 minutes after one prompt. | Security review; `refuse_system` was called only for protect/unprotect | High |
| 2 | Root opened user paths by name after checking them. An ancestor swapped for a link could make it create an empty file anywhere (e.g. `/etc/nologin`); a device or FIFO planted as the leaf was opened for real | Security review, code path traced | Medium |
| 3 | Map copied to `/run` with no size limit; only one line had to look like a map | Security review | Low |
| 4 | The helper never checked the disk sequence number. A drive swapped during the password dialog would be protected or imaged instead | Security review | Low |
| 5 | Thumbnails of untrusted files had a byte limit but no pixel limit | Security review | Low |
| 6 | Numbers read back from `state.env` reached `$(( ))`, where bash evaluates names (same user only) | Security review | Info |
| 7 | ddrescue saves its map every 30 s to 5 min by default. The image page read its progress from the map, so it stood still for minutes | Found while testing salvage | Medium (UX, resume point) |
| 8 | After `resume`, an image, search or salvage kept showing its old state ("paused") until the supervisor started | Found by a test | Low |
| 9 | `/tmp` mounted noexec silently disabled test stand-ins (an earlier "stuck stat" test was weakened because of it) | Diagnosed | Tests only |

Points 1 to 6 were confirmed by tracing the code. None had been exploited:
this work found no sign of misuse on the development machine. The security
review checked these areas and found them fine:
- job ids;
- `eval`/`source`;
- JSON escaping;
- rsync item handling;
- GTK markup;
- the results index.

## Leftovers of the migration

- **Renamed:** the GObject types `BigMountFileItem` and `BigMountResultsModel`, which were safe to rename.
- **Intentional mentions of Big-Mount**, kept on purpose:
  - the migration of its state;
  - `--doctor` looking at the installed big-mount;
  - the process names `bigmount`/`big-mount` that `--busy` recognizes;
  - `WORK_PREFIX=.big-mount` of migrated jobs.

## The source of the PKGBUILD

`source=("git+https://github.com/biglinux/big-storage-rescue.git")`.
- This is the BigLinux convention: packages are built from the organization's repository.
- Development happens in `ruscher/big-storage-rescue`. At the time of this audit, `biglinux/big-storage-rescue` `main` holds only the first commit (LICENSE).
- A build of the official package before `biglinux` `main` holds the code would therefore fail in `package()`, with no `usr/` folder.
- **Decision:** keep the official source, which is the right one for publishing. Merge into `biglinux/big-storage-rescue` before asking the BigLinux build service for a package.
- Local and fork builds use `pkgbuild/build-local.sh`, which never downloads anything.

## Opportunity matrix (summary)

Full matrix, with sources: doc 20 §8.

| Priority | Opportunity | Taken in this work |
| --- | --- | --- |
| P0 | Security findings 1–6 | yes |
| P0 | Partly readable and large files: block-level rescue with a map, partial result kept, holes listed | yes (salvage) |
| P0 | SHA-256 manifests of what was rescued, reading the destination only | yes |
| P0 | Map the unread areas of an image to the files they hit (fiwalk/ifind, ntfscluster) | no: roadmap |
| P1 | Damage map drawn from the ddrescue map | yes |
| P1 | Structural check of carved files | yes |
| P1 | ddrescue stop conditions (`--timeout`, `--max-read-errors`) | no: roadmap |
| P1 | Sleuth Kit browsing of deleted files on images, per-filesystem capability matrix | no: roadmap (doc 20 §4 has the matrix) |
| P1 | Open an image read-only (loop) inside the app; XFS `norecovery`, Btrfs `rescue=` there | no: roadmap |
| P1 | `smartctl -j` in the helper | no: roadmap |
| P2 | LVM/md from images, E01, ZFS read-only import, forensic case mode | no: roadmap |
