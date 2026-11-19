# 22 — Repairing a memory card or a USB drive

Everything else in Big Storage Rescue only **reads** the drive it works on.
The repair is the one exception: it tests a memory card or a USB drive and
sets it up again, and **it erases everything on it**. It exists because the
most common "broken drive" people bring is not a failing hard disk full of
photos, but a card or pen drive that:

- gives write errors (`I/O error … op 0x1:(WRITE)`, `lost async page write`),
  often only at its end;
- shows a capacity it does not have (a counterfeit card: "64 GB" that keeps
  only 8 and silently overwrites the rest);
- cannot be formatted by the file manager, or comes back half formatted.

For those, what a person needs is a clear answer (works / counterfeit / worn
at its end / dead, replace it) and, when it can still be used, a drive set up
to use only the part that works.

## What it does

```
 1 capacity   f3probe --destructive (when f3 is installed): the real capacity
              of the drive. A counterfeit card is set up with what it really has;
              a card that keeps nothing ("damaged") stops here: replace it
 2 surface    a pattern of its own on every block that is tested, written
              synchronously (O_DSYNC) and read back after dropping the cache
              of the device (BLKFLSBUF):
                quick  64 samples across the drive and its last 32 MiB, MiB by
                       MiB, where cheap cards fail first (about 100 MiB, minutes)
                full   every block (hours on a slow, large card)
              Different data coming back without an error is what a
              counterfeit card does: without f3 it is reported, not guessed
 3 partition  wipefs, then one MBR partition from 1 MiB to the first block that
              failed (or the real end), minus a margin (8 MiB by default)
 4 format     FAT32 up to 32 GiB, exFAT above (or what the person chose);
              ext4 belongs to the user (root_owner)
```

A failure in the first half of the drive, or a drive that refuses every
write, ends with **"This drive cannot be repaired. Replace it."**: a card that
fails that early fails again soon after.

## Where it can be used

Only a memory card (SD) or a USB drive, never the running system, never a disk
inside the computer. The checks are made twice:

| | the engine (`drive-repair.sh`, as the user) | the helper (`bsr-repair-helper`, as root) |
| --- | --- | --- |
| the running system | refused, said first | refused (exit 4) |
| SATA, NVMe, eMMC, optical | refused | refused (exit 6): only `removable=1`, `TRAN=usb` or an SD `mmcblk` |
| a disk image (loop) | only over a file of the user | the same, by the owner of the backing file |
| a partition | the whole drive it belongs to | refused: a whole drive only |
| mounted, LVM, RAID, open LUKS | listed, unmounted first by the window | refused (exit 7) |
| another drive under the same name | refused (disk sequence number) | refused (sequence number **and** size, exit 5) |
| the device opened by someone meanwhile | — | `O_EXCL`: nothing is written |

## Confirmations

- **The window**: a page of its own that says on its first line that the
  drive is erased, lists its volumes with their size and use, offers *Recover
  files first*, and starts only after the person ticks *I understand that
  everything on “NAME” will be erased for good*.
- **The terminal**: `big-storage-rescue --cli repair /dev/sdX` asks to type the
  name of the device (`sdX`); a script must say `--yes`. JSON without `--yes`
  is refused.
- **polkit**: its own action, `org.biglinux.big-storage-rescue.repair`, with
  `auth_admin` for every kind of session: the password is asked every time and
  never kept. pkexec picks an action by the path of the program alone, so the
  repair has a program of its own (`bsr-repair-helper`) that no other action
  names (`tests/package-check.sh`).

  Note: a local polkit rule can still let an administrator through without a
  password (some systems grant `wheel` everything). The checks of the helper
  do not depend on polkit and stay in force.

## A job like the others

It runs under a supervisor (`--cli __run ID`) that does not depend on the
window. The helper writes lines for it on its standard output:

```
@phase capacity|surface|partition|format|done
@step NAME ok|failed|skipped
@progress DONE TOTAL          bytes of the current step
@fact announced|real|tested|bad|first_bad|usable|last_sector N
@verdict real|fake|worn|damaged|inconsistent
```

and the job shows each step, then what it concluded, with the numbers:
announced capacity, real capacity, what was tested, what failed, what is
usable now. The log is `repair.out` in the job folder.

It can be stopped (the helper checks a stop file between blocks and stops
f3probe); the drive is then left without a filesystem, and the job says so.
**It is never resumed**: a card reader keeps its name and its serial number
when its card is swapped, so "the same drive" cannot be told, and a resume
could erase another card. *Repair again* opens the page again, with a new
confirmation.

## Command line

```
big-storage-rescue --cli repair DEV [--mode quick|full] [--filesystem auto|fat32|exfat|ext4]
                                    [--label NAME] [--margin-mib N] [--dry-run] [--yes] [--no-wait] [--json]
```

`--dry-run --json` is what the window asks: whether it can be repaired, what
is on it, what is mounted, the filesystem and name it would get, and the
warnings (`has-data`, `risky`, `no-f3`, `full-slow`, `exfat-old`,
`ext4-linux`, `fat-4g`).

Exit codes: 0, 2 bad option or no confirmation, 3 volumes mounted, 10 a repair
of it is running, 20 refused, 24 the drive was replaced, 25 a tool is missing
(the JSON names the package).

## Tools

| tool | package | needed for |
| --- | --- | --- |
| sfdisk, wipefs, blockdev | util-linux | always |
| python3 | python | the test of the surface |
| mkfs.fat / mkfs.exfat / mkfs.ext4 | dosfstools / exfatprogs / e2fsprogs | the filesystem chosen |
| f3probe | f3 | the real capacity (optional, recommended) |

## Tests

- `tests/drive-tests.sh`: refusals and plans on fixture drives, the job driven
  by a stand-in helper (counterfeit, damaged, stopped, password refused), the
  parser of f3probe on real outputs, where the partition ends, the test of the
  surface on a scratch file, and that only `bsr-repair-helper` runs a
  formatter. The whole suite runs with a stand-in for `pkexec` in `PATH`: on
  a system where polkit lets the user through without a password, a test that
  forgot `BSR_HELPER_CMD` would otherwise run the real helper as root.
- `tests/gui-tests.py` (`Repair`): offered on a USB drive and never on the
  system, what is erased is listed, nothing starts without the confirmation,
  mounted volumes are unmounted first and never forced, the exact command,
  steps and verdict on the job page, never a resume.
- By hand, as root, on loop devices only: quick FAT32, full exFAT, ext4 owned
  by the user; refusals; a drive whose last 4 MiB fail and a counterfeit one,
  both made with device-mapper (`error` target; two halves mapped on the same
  blocks).
