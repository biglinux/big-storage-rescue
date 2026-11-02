# 17 — Final report: Big-Mount split into Big-Mount 3.0 and Big Storage Rescue 1.0

Date: 2026-11-02. Everything below was done and checked on the development
machine; nothing was pushed, published or installed on the system.

## 1. Summary

Big-Mount 2.6 was an automount *and* a drive manager. It is now two
independent packages, from one history:

- **Big-Mount 3.0** (`ruscher/big-mount`, branch `feature/automount-only`):
  mounts internal partitions at boot. Same boot code, 7 files, 41 KB, 3
  dependencies.
- **Big Storage Rescue 1.0** (`biglinux/big-storage-rescue`, branch
  `feature/migrate-from-big-mount`): diagnosis, busy devices, safe removal,
  drive health, file rescue, images, TestDisk, PhotoRec, the GTK 4 application
  and the terminal manager, with its own name, identifiers, icon, polkit
  actions, gettext domain and package.

Secure Erase is in neither. The jobs, preferences and notifier of Big-Mount
2.x are brought over, never moved; a paused copy of Big-Mount resumes in Big
Storage Rescue with what it already wrote.

## 2. Initial state

See 01-source-audit.md: Big-Mount at `40612ab`, clean, 169 commits, all
branches merged; Big Storage Rescue empty. A real GNU ddrescue recovery of a
failing 200 GB drive was running through the installed Big-Mount 2.6 during
the whole work; it was never touched, and it became the real case of the
"running job" rule of the migration.

## 3–5. Files

**Migrated** (with `git mv`, history kept): `cli.sh`, `lib.sh`, `ui.sh`,
`doctor.sh`, `drive*.sh`, `drive-gui.py` → `app.py`, `dialog.py`, `gui/`,
`bigmount-drive-helper` → `bsr-drive-helper`, `bigmount-holders` →
`bsr-holders`, the desktop files, the polkit policy, the icon (redrawn), the
locale, the tests of all of these, the documents (in `docs/big-mount-history`).

**Refactored**: `cli.sh` (dispatcher, `--gui-rescue`, `--migrate-state`,
without Secure Erase), `lib.sh` (without Secure Erase), `doctor.sh` (checks
this package; Big-Mount optional), `drive-copy.sh` (`WORK_PREFIX`, the lock of
migrated jobs, `resume` refused while Big-Mount runs the job), `gui/*`
(identity, no maintenance page, rescue route), every `bm_`/`BM_` name.
**New**: `/usr/bin/big-storage-rescue`, `migrate.sh`, metainfo,
`tests/migrate-tests.sh`, `tests/coexistence-check.sh`, docs 01–17.

**Removed from Big-Mount** (see Big-Mount `docs/02-split.md`): everything
above, Secure Erase, 13 test files; `cli.sh` rewritten in 271 lines.

## 6–7. Architecture and commands

03-architecture.md and 11-cli.md. One engine in bash, one window in Python
that only calls `big-storage-rescue --cli … --json`.

## 8. The window

10-gtk-libadwaita-ux.md: same components and style, own identity, no erase,
`--gui-rescue`, About and welcome updated, screenshots redrawn.

## 9. Translations

13-i18n.md: 1090 messages kept with their pt_BR translation, 45 new or
rewritten by hand, 1135 in total, none fuzzy. Big-Mount keeps 66.

## 10. Dependencies

14-packaging.md and Big-Mount `docs/04-dependencies.md`.

## 11. Security

12-security.md. Nothing runs as root but two pkexec helpers with checked
arguments; no daemon; no write to a source; Secure Erase removed; device
identity checked by disk sequence number.

## 12–13. Tests and results

15-testing.md. All automated suites pass (Big Storage Rescue: lib 228, drive
299, migrate 41, i18n 37, package 100, GUI 163, e2e 7; Big-Mount: boot 132,
i18n 26, package 31; coexistence 18), ShellCheck, `bash -n` and ruff clean.

## 14. Performance

| | Big-Mount 2.6 | Big Storage Rescue / Big-Mount 3.0 |
| --- | --- | --- |
| window until the list is asked | 1607 ms | 1567 ms |
| window memory idle | 102 MiB | 97 MiB |
| window CPU idle (20 s) | 0 | 0 |
| `--cli list --json` | 297 ms | 294 ms |
| `--diagnose` | 41 ms | 41 ms |
| boot code | — | identical |
| `bigmount --help` | 7 ms | 3 ms |
| Big-Mount installed | 803 KB, 45 files, 13 deps | 41 KB, 7 files, 3 deps |

Single runs or best of six on one machine: equal within noise, as expected
from moving code without changing it.

## 15–16. Installation and use

README.md of each repository.

## 17. Problems fixed on the way

- `libadwaita>=1.5` accepted any version (epoch `1:`): now `>=1:1.5`.
- Big-Mount's PKGBUILD license `GPL` (ambiguous SPDX): `GPL-3.0-or-later`,
  as the About of the application says.
- The test suites could have migrated the real home folder: every suite now
  isolates `XDG_STATE_HOME` and `XDG_CONFIG_HOME`.
- `lib-tests.sh` stopped in the Secure Erase cases before any change; the
  feature and its tests are gone, and the suite runs to the end.
- The GUI test stand-in and the application's runtime folder had the same
  name once renamed; the stand-in is `bsr-stand-in`.

## 18. Known limitations

README §10 and 15-testing.md: real UDisks2 suites (`integration.sh`,
`drive-integration.sh`) and a real boot with Big-Mount 3.0 were not run on
this machine while its recovery job was running; real LVM/RAID/SD/eMMC, a
screen reader and the polkit password dialog are not validated on hardware.

## 19. Pending, verified

- Push `feature/migrate-from-big-mount` to `biglinux/big-storage-rescue` and
  `feature/automount-only` to `ruscher/big-mount` (then a pull request to
  `biglinux/big-mount`). Until Big Storage Rescue is on GitHub, its PKGBUILD
  cannot be built by the BigLinux build service.
- After installing both packages: `tests/manual-check.sh` of each repository,
  `tests/integration.sh` and `tests/drive-integration.sh` of Big Storage
  Rescue, and `tests/bench.sh` of Big-Mount.
- Update Big-Mount on the development machine only after its ddrescue job
  ends (14-packaging.md).

## 20. Recommendations

- Publish both packages in the same repository update, so that nobody has two
  applications in the menu for long.
- More languages: the catalog is ready (`msginit`), and the texts are short.
- A destructive-maintenance tool, if ever wanted, should be its own package,
  with its own review.

## Branches and commits

Big Storage Rescue, `feature/migrate-from-big-mount` (on top of the Big-Mount
history up to `40612ab`):

```
6c3dcd9 Take the storage rescue application out of Big-Mount
fcf9225 Make the engine and the command line Big Storage Rescue
7b78e4d Make the application Big Storage Rescue, without Secure Erase
03e576f Give Big Storage Rescue its own desktop identity and translations
e87531d Package big-storage-rescue beside big-mount
5e6e56d Adapt the tests to Big Storage Rescue
5fd0fdb Document Big Storage Rescue
```

plus the commit of this report and of the coexistence check. Big-Mount,
`feature/automount-only` (from `feature/biglinux-2.6.0`, `40612ab`):

```
3d1184a Mount at boot, and leave everything else to Big Storage Rescue
c4cde96 Keep only the tests of the automount
95d0bef Document Big-Mount as the automount only
5e5161b Name the license of the package in SPDX form (GPL-3.0-or-later)
```

plus the commit that records the coexistence results. `main` of Big Storage Rescue has
no commit yet; `feature/biglinux-2.6.0` of Big-Mount is unchanged.
