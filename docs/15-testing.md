# 15 — Tests

## Suites

| Suite | What | Needs | In CI |
| --- | --- | --- | --- |
| `tests/lib-tests.sh` | read-only causes, process policy, unmount decisions, escaping, drive health, `--version`/`--doctor`, absence of Secure Erase | bash | yes |
| `tests/drive-tests.sh` | drive manager with fixtures (NVMe, LUKS, LVM, Btrfs, SD, eMMC, loop), JSON, refusals, exit codes, real scan and copy jobs on scratch files, forbidden commands | bash, rsync | yes |
| `tests/migrate-tests.sh` | state of Big-Mount 2.x, including a real paused copy resumed here | bash, rsync, /dev/shm | yes |
| `tests/i18n-tests.sh` | catalog complete and current, placeholders, generated files, language at run time | gettext | yes |
| `tests/package-check.sh` | `package()` on the checkout: files, modes, nothing of Big-Mount, metadata, desktop files, polkit, AppStream | desktop-file-utils, libxml2, appstream (optional) | yes |
| `tests/gui-tests.py` | the window with a stand-in engine, on a private Broadway display | gtk4, libadwaita, python-gobject | yes |
| `tests/gui-e2e.py` | the window with the real engine, on scratch files | same, rsync | yes |
| `tests/integration.sh` | diagnosis, busy, removal, notifier on real loop devices through UDisks2 | a local session, polkit | by hand |
| `tests/drive-integration.sh` | real filesystems, dm-error, dm-delay, power cut, LUKS | a session, sudo for device-mapper | by hand |
| `tests/manual-check.sh` | what a person must see: dialogs, notifications, Dolphin menu | a Plasma session | by hand |
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
