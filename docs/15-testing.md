# 15 — Tests

## Suites

| Suite | What | Needs | In CI |
| --- | --- | --- | --- |
| `tests/lib-tests.sh` | read-only causes, process policy, unmount decisions, escaping, drive health, earlier starts and filesystem counters, the running system, `--version`/`--doctor`, absence of Secure Erase | bash | yes |
| `tests/drive-tests.sh` | drive manager with fixtures (NVMe, LUKS, LVM, Btrfs, SD, eMMC, loop), JSON, refusals, exit codes, real scan and copy jobs on scratch files, forbidden commands | bash, rsync | yes |
| `tests/migrate-tests.sh` | state of Big-Mount 2.x, including a real paused copy resumed here | bash, rsync, /dev/shm | yes |
| `tests/i18n-tests.sh` | catalog complete and current, placeholders, generated files, language at run time | gettext | yes |
| `tests/package-check.sh` | `package()` on the checkout: files, modes, nothing of Big-Mount, metadata, desktop files, polkit, AppStream | desktop-file-utils, libxml2, appstream (optional) | yes |
| `tests/gui-tests.py` | the window with a stand-in engine, on a private Broadway display | gtk4, libadwaita, python-gobject | yes |
| `tests/gui-e2e.py` | the window with the real engine, on scratch files | same, rsync | yes |
| `tests/integration.sh` | diagnosis, busy, removal, notifier on real loop devices through UDisks2 | a local session, polkit | by hand |
| `tests/drive-integration.sh` | real filesystems, dm-error, dm-delay, power cut, LUKS | a session, sudo for device-mapper | by hand |
| `tests/manual-check.sh` | what a person must see: dialogs, notifications, Dolphin menu | a Plasma session | by hand |
| `tests/coexistence-check.sh` | real pacman transactions of Big-Mount 2.6, Big-Mount 3.0 and Big Storage Rescue in scratch roots | the three packages, fakeroot | by hand (18 passed on 2026-11-02) |
| `tests/measure-app.py`, `tests/measure-session.sh` | cost of the window; latency of the session tools | | by hand |

No suite touches a real disk: devices are fixtures, scratch folders or loop
images. Every suite that runs the program isolates `XDG_STATE_HOME` and
`XDG_CONFIG_HOME`, so the migration of Big-Mount state never reads the real
home folder.

## Results on 2026-11-02 (development machine, Arch-based, kernel 7.2, bash 5.3, GTK 4.22, libadwaita 1.9)

| Suite | Before (Big-Mount 2.6) | After (Big Storage Rescue) | Difference |
| --- | --- | --- | --- |
| lib-tests | stopped by a Secure Erase failure | **228 passed, 0 failed** | erase cases removed with the feature; 4 checks of its absence added |
| drive-tests | 293 passed | **299 passed** | help and alias checks; forbidden-command list extended (SecurityEraseUnit, hdparm, nvme format/sanitize) |
| migrate-tests | — | **41 passed** | new |
| i18n-tests | 38 passed | **37 passed** | 3 boot-message checks moved to Big-Mount; 2 added (`--cli --help`, `--migrate-state`) |
| package-check | 99 passed | **100 passed** | new file list; coexistence, epoch of libadwaita, AppStream |
| gui-tests | 179 passed | **163 passed** | 17 Secure Erase tests removed; checks that no erase is reachable; 2 for `--gui-rescue` |
| gui-e2e | 8 passed | **7 passed** | 2 erase tests replaced by one: the engine has no erase |
| ShellCheck (CI set), `bash -n`, ruff | clean | clean | |

`integration.sh` and `drive-integration.sh` were **not** run in this work: a
real GNU ddrescue recovery was running on the machine through the installed
Big-Mount, and these suites attach and detach devices through UDisks2 and
device-mapper. They were adapted (names, `--cli`) and checked by ShellCheck
only.

## Measurements (same machine, same conditions, see 17-final-report.md)

| | Big-Mount 2.6 | Big Storage Rescue |
| --- | --- | --- |
| window: until the list is asked for | 1607 ms | 1567 ms |
| window: memory when idle (RSS) | 102 MiB | 97 MiB |
| window: CPU when idle, 20 s | 0 ms | 0 ms |
| `--help` | 7 ms | 7 ms |
| `--cli list --json` (6 drives) | 297 ms | 294 ms |
| `--diagnose` overview | 41 ms | 41 ms |

One run of `measure-app.py` each and the best of six runs of each command:
the differences are within noise. The split did not make it slower.

## After the checks of 18-system-and-history-checks.md (same day)

| Suite | Before | After |
| --- | --- | --- |
| lib-tests | 228 | **267 passed** (39 new) |
| drive-tests | 299 | **312 passed** (13 new) |
| migrate-tests | 41 | **41 passed** |
| i18n-tests | 37 | **37 passed** (26 new messages translated) |
| package-check | 100 | **102 passed** (the new `system-check.sh`: installed with its mode, and its syntax) |
| gui-tests | 163 | **165 passed** (2 new) |
| gui-e2e | 7 | **7 passed** |
| ShellCheck (CI set), `bash -n`, ruff | clean | clean |

`--cli list --json` (6 drives, warm cache): about 345 ms before, 358 ms after.

## After the work of 00, 20 and 21 (2026-11-03)

| Suite | Before (`146bde8`) | After |
| --- | --- | --- |
| lib-tests | 267 | **267 passed** (the stuck-statfs check runs a real hung `stat` again) |
| drive-tests | 312 | **380 passed** (salvage with real GNU ddrescue, map, integrity, manifests, the helper's opener) |
| migrate-tests | 41 | **41 passed** |
| i18n-tests | 37 | **37 passed** |
| package-check | 102 | **107 passed** (new modules, the image polkit action) |
| gui-tests | 165 | **173 passed** |
| gui-e2e | 7 | **7 passed** |
| ShellCheck (CI set), `bash -n`, ruff | clean | clean |

## After the second review (2026-11-03)

The fixes of the CodeRabbit review of biglinux PR #1 (docs/21).

| Suite | Before (`60a30c8`) | After |
| --- | --- | --- |
| lib-tests | 267 | **278 passed** (which disks hold a folder, shares through this computer's addresses; the erase check really looks) |
| drive-tests | 386 | **393 passed** (the engine's own block check, image refusals, the helper) |
| migrate-tests | 41 | **54 passed** (a failed or unreadable job is tried again; the lock is let go; no migration on a dry run) |
| i18n-tests | 37 | **37 passed** |
| package-check | 108 | **112 passed** (`bsr-image-helper`; no two polkit actions share a program) |
| gui-tests | 174 | **174 passed** |
| gui-e2e | 7 | **7 passed** |
| drive-integration `image protect` | never run | **36 passed** (the helper as root on loop devices, with sudo) |
| ShellCheck (CI set), `bash -n`, ruff | clean | clean |

Stand-ins that a test runs through another program (ionice, timeout) live
in `/var/tmp`, whatever `TMPDIR` says. `/tmp` may be mounted noexec, and an
`execvp` then quietly runs the real program instead. Salvage tests use GNU ddrescue itself, told
which areas are bad (`--test-mode`) or how fast it may read
(`--max-read-rate`). CI installs `ddrescue` for them.
