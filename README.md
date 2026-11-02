<p align="center">
  <img src="big-storage-rescue/usr/share/icons/hicolor/scalable/apps/big-storage-rescue.svg" width="128" alt="Big Storage Rescue">
</p>

<h1 align="center">Big Storage Rescue</h1>

<p align="center">
  Find out what is wrong with a drive, why it cannot be written to or removed,
  and rescue your files from it — without writing to the drive that is failing.<br>
  Made for <a href="https://www.biglinux.com.br">BigLinux</a> (Manjaro/Arch, KDE Plasma 6, Wayland and X11).
  It also works on GNOME, and every tool works in a terminal, also over SSH.
</p>

<p align="center">
  <img src="docs/images/app-overview.png" width="720" alt="Big Storage Rescue: every drive, with its health and what can be done">
</p>

---

## Contents

1. [What it does](#1-what-it-does)
2. [Installation](#2-installation)
3. [Rescue files, step by step](#3-rescue-files-step-by-step)
4. [Why can't I write here?](#4-why-cant-i-write-here)
5. [Busy devices and safe removal](#5-busy-devices-and-safe-removal)
6. [The terminal](#6-the-terminal)
7. [Big-Mount and Big Storage Rescue](#7-big-mount-and-big-storage-rescue)
8. [Safety](#8-safety)
9. [Development](#9-development)
10. [Known limitations](#10-known-limitations)
11. [License](#11-license)

## 1. What it does

| | |
| --- | --- |
| **Every drive at a glance** | internal and external, mounted or not, NVMe, SATA, USB, SD, eMMC, disk images, LUKS and LVM — with its health in one word (*Critical, Poor, Good, Healthy*) and the facts behind it |
| **Health** | SMART and NVMe health (temperature, hours, wear, errors) and the kernel log of this boot, read without touching the disk |
| **Why can't I write here?** | Windows Fast Startup, filesystem errors, write-protected cards, permissions, another operating system… explained in plain words, fixed when that is safe |
| **Busy devices** | which programs keep a device busy, and what else does (another mount, swap, a container, a service) |
| **Safe removal** | unmounts, locks encrypted volumes and powers the drive off, without forcing anything |
| **Rescue files** | copies files off a failing disk with real progress, pause and resume — also after a power cut — and a check of the result |
| **When files cannot be reached** | a disk image with GNU ddrescue, lost partitions with TestDisk, files by content with PhotoRec |
| **Reports** | technical reports of a drive or of a copy, anonymized on request |

What it never does to the drive it rescues from: format, repair, rewrite a
partition table, force an unmount or kill programs. See [Safety](#8-safety).

## 2. Installation

### From the BigLinux repository

```bash
sudo pacman -Syu big-storage-rescue
```

Optional tools, used when present: `ddrescue` (disk images), `testdisk`
(lost partitions and PhotoRec), and `big-mount` (mounts internal partitions at
boot).

### Build the package yourself

```bash
git clone https://github.com/biglinux/big-storage-rescue.git
cd big-storage-rescue/pkgbuild && makepkg -si
```

Nothing runs at boot and nothing is enabled: the application opens when you
open it. Requirements: bash, util-linux, udisks2, polkit, lsof, rsync,
smartmontools, Python with PyGObject, GTK 4 and libadwaita 1.5 or later,
libnotify.

### Coming from Big-Mount 2.x

The drive manager of Big-Mount 2.x is now this application. Copies and images
started there, the preferences of the window and the read-only notifier are
brought over the first time Big Storage Rescue opens; the originals stay in
`~/.local/state/big-mount` as a backup, and a copy that was paused resumes
here with what it already wrote. A job that is still running in Big-Mount is
left alone and brought over when it ends. To see what would happen:
`big-storage-rescue --migrate-state --dry-run`.

## 3. Rescue files, step by step

Open **Big Storage Rescue** from the menu, or right-click a folder in Dolphin →
**Storage device** → **Recover files from this drive…**.

**1. Look at the drive.** Home lists every drive with its health in one word
and an icon, never colour alone. *Not examined* is never shown as *no alerts*.

<p align="center">
  <img src="docs/images/app-health.png" width="620" alt="The health of a failing disk: critical, what was found, and what to do">
</p>

**2. Recover files** opens an assistant: *from where → what → how → where to →
confirm*, with Back losing nothing. The way advised first depends on the
drive: on a healthy volume, a list of the files to choose from; on a drive at
risk, a copy of what matters, without walking the whole disk; when the
volume cannot be opened, a disk image first.

<p align="center">
  <img src="docs/images/app-rescue-how.png" width="620" alt="The advised way first, with why">
  <img src="docs/images/app-rescue-where.png" width="620" alt="Places on another disk; the same physical disk cannot be chosen">
</p>

**3. Follow the job.** It runs in the background, with or without the window:
current file, files and bytes, speed, elapsed and remaining time, files that
failed or were set aside. Pause and resume are shown only for the jobs that
support them.

<p align="center">
  <img src="docs/images/app-job-running.png" width="620" alt="A copy in progress, with real numbers">
</p>

**4. Results.** Four words that never mean the same thing:

| Word | Meaning |
| --- | --- |
| **Found** | a file listed on the volume |
| **Candidate** | a file PhotoRec reconstructed from its content: no name, maybe incomplete |
| **Recovered** | a file written to the destination and synced |
| **Verified** | a recovered file compared with the source, and equal |

## 4. Why can't I write here?

```bash
big-storage-rescue --diagnose /run/media/me/PENDRIVE
```

Or Dolphin → **Storage device** → **Why can't I write here?**. A damaged drive
is never presented as a simple restriction, and a restriction is never
presented as damage: the diagnosis starts with the hardware and the kernel log
before permissions. Details: [docs/05](docs/05-readonly-diagnostics.md).

<p align="center">
  <img src="docs/images/app-dialog-read-only.png" width="520" alt="A read-only device explained">
</p>

## 5. Busy devices and safe removal

```bash
big-storage-rescue --busy /run/media/me/PENDRIVE
big-storage-rescue --safe-remove /run/media/me/PENDRIVE [--close-apps]
```

The programs keeping it busy are named, with what they are doing. Closing them
is offered only for your own programs that are not writing, and only after
you confirm. Services that would stop are listed first. Internal disks are
unmounted, never powered off. Details: [docs/06](docs/06-busy-processes.md),
[docs/07](docs/07-safe-removal.md).

## 6. The terminal

```bash
big-storage-rescue --cli                 # menus, in any terminal
big-storage-rescue --cli --help          # every command
big-storage-rescue --cli list --json     # for scripts
```

Every operation of the window is a command, and the window uses those same
commands: they always agree. `--json` gives stable machine-readable output,
`--dry-run` says what would be done. Exit codes and examples:
[docs/11](docs/11-cli.md).

| Option | |
| --- | --- |
| *(none)* | the application in a graphical session, the menus in a terminal |
| `--gui [TARGET]`, `--gui-health`, `--gui-rescue` | the application, opened on a drive, its health or the recovery |
| `--cli [COMMAND]` | the drive manager |
| `--diagnose [TARGET]`, `--busy`, `--unmount`, `--safe-remove` | diagnosis and removal |
| `--gui-diagnose`, `--gui-remove` | the Dolphin actions |
| `--notifier` | warns about read-only devices (off by default; switch in the menu) |
| `--migrate-state [--dry-run]` | bring over the state of Big-Mount 2.x |
| `--doctor`, `--version`, `--help` | |

## 7. Big-Mount and Big Storage Rescue

| | Big-Mount | Big Storage Rescue |
| --- | --- | --- |
| Mounts internal partitions at boot | yes | no |
| Runs at boot | yes, `big-mount.service` | never |
| Diagnosis, busy devices, safe removal, health, rescue | no | yes |
| Graphical interface | no | yes |

They are independent packages that can be installed together, one of them, or
neither, without file conflicts. When Big-Mount is present, Big Storage Rescue
reads what it left in `/run/big-mount/status` to explain why a partition was
mounted read-only at boot, and shows its state in `--doctor`. It never
changes Big-Mount's configuration or restarts its service.

## 8. Safety

- Runs as your user. What needs more goes through UDisks2 and polkit, or two
  small helpers through pkexec, with the administrator password: no daemon,
  nothing permanent. [docs/12](docs/12-security.md)
- A drive at risk is mounted read-only, and can be blocked at the device level.
- Destination checks: never inside the source, never on the same physical disk
  (through partitions, LUKS and LVM) unless you insist in the terminal, enough
  room, existing files kept.
- Device names are never trusted across time: the disk sequence number is
  checked before every operation that cannot be undone.
- Secure Erase, formatting and repairs are not part of this tool.
- When the hardware itself is failing (heads, controller, firmware, NAND), no
  software can fix it. If the data is very important, stop and consider a data
  recovery professional before insisting.

## 9. Development

```text
big-storage-rescue/usr/bin/big-storage-rescue    entry point
big-storage-rescue/usr/lib/big-storage-rescue/   engine (bash) and application (Python, GTK 4)
locale/                                          gettext catalog, templates
pkgbuild/                                        PKGBUILD
tests/                                           test suites
docs/                                            technical documentation (01–17)
```

```bash
bash tests/lib-tests.sh        # diagnosis, process policy, health
bash tests/drive-tests.sh      # drive manager with fixtures, real jobs on scratch files
bash tests/migrate-tests.sh    # state of Big-Mount 2.x, a real resume
bash tests/i18n-tests.sh       # translations
bash tests/package-check.sh    # package() on this checkout
python3 tests/gui-tests.py     # the window, on a private Broadway display
python3 tests/gui-e2e.py       # the window with the real engine, on scratch files
```

`tests/integration.sh` and `tests/drive-integration.sh` use real loop devices
and need a local session with UDisks2. No test touches a real disk.
Architecture and decisions: [docs/03](docs/03-architecture.md) and the rest of
[docs/](docs). The history of the code, from Big-Mount 2.0 to 2.6, is kept in
git and in [docs/big-mount-history](docs/big-mount-history).

Translations: `locale/update-pot.sh`, translate, `locale/compile.sh`
([docs/13](docs/13-i18n.md)).

## 10. Known limitations

- Resuming works per file: a large file that was interrupted starts over. A
  file with read errors is not saved in part: a disk image keeps what can be read.
- `--protect` lasts until the drive is disconnected. Clicking a failing disk in
  Dolphin mounts it with writing enabled before this program can protect it:
  that is the policy of UDisks2 and the desktop.
- XFS and Btrfs with an unclean log cannot be mounted through UDisks2 without
  replaying it.
- The first read of a damaged area can take minutes, and `cancel` waits for it.
- Owners are not preserved: a copy does not run as root. A file of 4 GiB or
  more cannot go to FAT32 and is listed as failed.
- As a user, only your own processes are listed; the others need the password.
- Plasma does not let other programs add actions to its own unmount error: the
  diagnosis lives in the Dolphin menu, the launcher and the terminal.
- Not validated on real hardware by this project yet: the password dialog of
  the helper, LVM, RAID, multi-device Btrfs, SD and eMMC (detected from
  fixtures), a screen reader, a real GNOME session. GNU ddrescue was run for
  real only by Big-Mount 2.6 in the field, not by the tests.

## 11. License

[GNU General Public License v3.0](LICENSE). Big Storage Rescue started from the
code of Big-Mount, by the BigLinux team; the full history and authorship are
in git.
