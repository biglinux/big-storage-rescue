# 14 — Packaging (BigLinux, Manjaro, Arch)

`pkgbuild/PKGBUILD` builds `big-storage-rescue`, `arch=any`, version from the
build date as every BigLinux package (`pkgver=YY.MM.DD`, `pkgrel=HHMM`); the
commit goes to `/usr/lib/big-storage-rescue/version` for `--version`.

| Field | Value | Why |
| --- | --- | --- |
| `depends` | bash, util-linux, udisks2, polkit, lsof, rsync, smartmontools, python, python-gobject, gtk4, `libadwaita>=1:1.5`, libnotify | each is called by the code (checked with `grep` of every tool name, see 01) |
| `optdepends` | ddrescue, testdisk, big-mount | images; lost partitions and PhotoRec; mounting at boot |
| `provides` / `conflicts` / `replaces` | none | it is a new package beside big-mount, not a replacement |
| `backup` | none | no file in `/etc` |
| `install` | `big-storage-rescue.install` | messages only: nothing is started or enabled |
| `source` | `git+https://github.com/biglinux/big-storage-rescue.git` | the official repository |

`nvme-cli` is not a dependency: NVMe health is read from UDisks2 and the
helper uses `smartctl`. Names were checked against the Arch repositories
(`pacman -Si`, 2026-11-02): all exist in `core`/`extra`.

**Before the first build**: the source URL points to
`biglinux/big-storage-rescue`, which is empty until this branch is pushed and
merged there. Until then the package can only be built from a local clone
(`tests/package-check.sh` runs `package()` on the checkout, without network).

## Installed files

Only `/usr`: `/usr/bin/big-storage-rescue`, `/usr/lib/big-storage-rescue/`,
`/usr/share/applications/org.biglinux.big-storage-rescue.desktop`,
`/usr/share/metainfo/org.biglinux.big-storage-rescue.metainfo.xml`,
`/usr/share/icons/hicolor/scalable/apps/big-storage-rescue.svg`,
`/usr/share/kio/servicemenus/big-storage-rescue.desktop`,
`/usr/share/polkit-1/actions/org.biglinux.big-storage-rescue.policy`,
`/usr/share/big-storage-rescue/big-storage-rescue-notifier.desktop` (copied to
`~/.config/autostart` only when the person turns the notifier on),
`/usr/share/locale/*/LC_MESSAGES/big-storage-rescue.mo`.

## Coexistence with big-mount

No path of this package contains `big-mount` or `bigmount`
(`tests/package-check.sh`), so pacman never sees two owners for a file, with
the old Big-Mount 2.6 or with the new one:

| Installed | Result |
| --- | --- |
| only big-mount (new) | mounts at boot; old options print the new command |
| only big-storage-rescue | everything works; `--doctor` says Big-Mount is not installed |
| both (new) | one application in the menu, one Dolphin submenu, the boot status file is used by the diagnosis |
| big-storage-rescue + big-mount 2.6 (not yet updated) | no file conflict; two applications and two sets of Dolphin actions until big-mount is updated; `--doctor` warns |
| remove either | the other is untouched |

The Dolphin submenu of both versions is named *Storage device*, so during that
transition their actions appear in one submenu.

**Do not update big-mount while one of its jobs runs** (a copy or an image
started by Big-Mount 2.6): the update replaces the scripts its supervisor is
reading. Let the job finish or pause it first; it is then brought over to
Big Storage Rescue and resumed there.
