# 01 — Audit of the source

Audit made on 2026-11-02, before any change.

## Repositories

| | Big-Mount (source) | Big Storage Rescue (destination) |
| --- | --- | --- |
| Path | `~/Documentos/Git/big-mount` | `~/Documentos/Git/big-storage-rescue` |
| Remote | `git@github.com:ruscher/big-mount.git` (fork of `biglinux/big-mount`) | `https://github.com/biglinux/big-storage-rescue.git` |
| Branch | `feature/biglinux-2.6.0`, clean, in sync with `origin` | `main`, no commit (empty repository) |
| HEAD | `40612ab` Refuse a Secure Erase check that saw two drives under one name | — |
| History | 169 commits, 7 authors; all 16 local branches already merged into HEAD | — |

## What Big-Mount 2.6.0 contained

141 tracked files, about 25,000 lines without the images.

| Part | Files | Role |
| --- | --- | --- |
| Boot automount | `usr/bin/bigmount` (562 lines), `big-mount.service`, `/etc/big-mount.conf`, `big-mount.hook` | mounts internal partitions under `/mnt` at boot, writes `/run/big-mount/status` |
| Command line | `cli.sh` (1624), `lib.sh` (1376), `ui.sh` (247), `doctor.sh` (466) | diagnosis, busy devices, safe removal, Secure Erase, notifier, `--doctor` |
| Drive manager | `drive.sh`, `drive-detect.sh`, `drive-diag.sh`, `drive-copy.sh` (1588), `drive-recovery.sh` (1168), `drive-tui.sh`, `drive-erase.sh` | `bigmount --drive`: detection, health, copy jobs, ddrescue, TestDisk, PhotoRec, terminal menus |
| Application | `drive-gui.py`, `gui/` (13 modules + 7 pages), `dialog.py`, `style.css` | GTK 4 / libadwaita, calls `bigmount --drive … --json` only |
| Privileged helpers | `bigmount-drive-helper`, `bigmount-holders` | pkexec: protect, SMART, TestDisk, ddrescue; `lsof` of every user |
| Desktop | launcher, Dolphin service menu, notifier autostart entry, polkit policy (2 actions), icon | |
| Translations | `locale/` (pot, `pt_BR.po` with 1231 messages, templates, ITS rules) | one gettext domain, `big-mount` |
| Tests | 16 files | stubs, real loop devices, Broadway GUI tests, packaging, i18n |
| CI | `tests.yml` (Arch container), `translate-and-build-package.yml` (BigLinux: automatic translations, then the build service) | |

## Findings

- **The boot path was already isolated.** `bigmount` loads `/usr/lib/big-mount/cli.sh`
  only for options; without them it uses bash builtins and a few util-linux
  commands. Splitting did not need to change the automount itself.
- **One engine.** The window never decides anything: every fact comes from
  `bigmount --drive … --json`. The split could move the engine and the window
  together without duplicating logic.
- **Persistent state in the home folder**: `~/.local/state/big-mount/jobs/ID`
  (job.conf, state.env, logs, maps) and `~/.config/big-mount/gui.ini`. The
  destination of a copy holds `.big-mount-tmp-ID` and `.big-mount-backup-ID`.
- **A job was running during the audit**: a GNU ddrescue image of a 200 GB
  Maxtor drive (`/dev/sde`), supervised by the installed Big-Mount. Nothing in
  this work touched that device, those processes or the installed packages; it
  became the first real case of the "job still running" rule of the migration.
- **Secure Erase** (`drive-erase.sh`, parts of `lib.sh`/`cli.sh`, the maintenance
  page) is destructive maintenance, not recovery.
- **Baseline of the tests, before any change**:

  | Suite | Result |
  | --- | --- |
  | `run-tests.sh new` (boot) | 115 passed |
  | `lib-tests.sh` | **stopped**: 2 failures in the Secure Erase cases, then `ER_CALLS[0]: unbound variable` |
  | `drive-tests.sh` | 293 passed |
  | `i18n-tests.sh` | 38 passed |
  | `package-check.sh` | 99 passed |
  | `gui-tests.py` | 179 passed (112 s) |
  | `gui-e2e.py` | 8 passed |

- `libadwaita>=1.5` in the PKGBUILD accepted any version: the Arch package has
  an epoch (`1:1.9.4`). Fixed in both packages (`>=1:1.5`).
