# 05 — Why a device cannot be written to

`bsr_diagnose_write` (`lib.sh`) decides one cause; `bsr_cause_text` (`cli.sh`)
explains it. The order goes from the hardware up, so a restriction is never
taken for damage and damage is never hidden behind a restriction.

| Cause | Evidence | What is said or offered |
| --- | --- | --- |
| `hw-readonly` | the block device is read-only (`ro` in sysfs). Where it comes from is said apart (below) | depends on where it comes from |
| `unsupported` | the driver cannot write it (ISO 9660, SquashFS, HFS+ with journal, APFS) | copy elsewhere; formatting erases everything |
| `ntfs-unsafe` | ntfs-3g refused writing: hibernated, Fast Startup, unclean | shut Windows down fully, disable Fast Startup, `chkdsk /f`; never repaired from Linux |
| `fs-errors` | the kernel remounted it read-only after errors (ext4, Btrfs, XFS, F2FS) | copy first, check with the device unmounted |
| `io-errors` | I/O errors of this device in the kernel log | copy first; cable, port, SMART |
| `mounted-ro` | mounted read-only with no problem found | **fix**: remount with writing (asks first) |
| `permission` | writable, but the top folder belongs to another user | **fix**: become owner of the top folder only, not recursive |
| `permission-os` | a partition with another operating system | use a folder of your own |
| `permission-folder` | a folder of another user | |
| `permission-other-user` | FAT/NTFS mounted for another user | **fix**: mount again for this user; for Big-Mount partitions, `PERMISSIONS` in `/etc/big-mount.conf` |
| `system`, `swap` | the running system, swap | |

A diagnosis of a partition also reports the errors of its drive
(`bsr_drive_health`: SMART, timeouts, I/O errors, link slow-downs, USB resets
of this boot), so a "read-only" volume on a dying disk is presented as a disk
problem. When Big-Mount mounted the partition at boot, its reason from
`/run/big-mount/status` (e.g. `ntfs-hibernated`) is used as evidence.

Corrections are offered only when they are safe and verifiable (`D_FIX`); none
writes to the data on the device. Never done: `ntfsfix`, `fsck` with repair,
`btrfs check --repair`, remounting a suspicious device with writing.

Commands: `big-storage-rescue --diagnose [TARGET]`, `--gui-diagnose TARGET`
(Dolphin: *Why can't I write here?*), `--cli diagnose TARGET [--json]`.
Tests: `tests/lib-tests.sh` (every cause with stubbed facts),
`tests/integration.sh` (real loop devices). Details of the reasoning:
`big-mount-history/04-read-only-diagnostics.md`.

## Where a write protection comes from

`bsr_write_protect DISK` (lib.sh) tells the cases of `hw-readonly` apart, from
sysfs and the kernel log of this boot only, without touching the drive. It is
said for the whole drive in `--cli diagnose` (and in the window, on the drive
and in its Health tab) even when nothing is mounted, which is when a person
usually asks.

| `WP_KIND` | Evidence | What is said or offered |
| --- | --- | --- |
| `switch` | USB/SCSI: the last `[sdX] Write Protect is on` of this boot (the reader answers again when a card is changed); SD on a native reader: `mmcblkN: … (ro)` | the switch of the card or adapter, a loose switch (another adapter, tape over the notch), another reader; if it stays locked in two readers, the card locked itself: copy and replace |
| `card-temporary` | SD: bit 12 of the CSD register (`TMP_WRITE_PROTECT`) | stored inside the card; the device that locked it may unlock it; no safe tool on Linux |
| `card-permanent` | SD: bit 13 of the CSD (`PERM_WRITE_PROTECT`) | locked for good: copy now, replace the card (shown as critical) |
| `software` | `ro=1` while the drive answered `Write Protect is off`, `force_ro=1`, or only a partition is read-only | not the switch: **fix** *Allow writing again* (`unprotect`, administrator password; the helper refuses the running system) |
| `chosen` | blocked in Big Storage Rescue for this connection (`protect`) | **fix** *Allow writing again*; never reported as a problem by the notifier |
| `image` | a loop device attached read-only | attach it again with writing enabled |
| `unknown` | `ro=1` and nothing in the log | the general text: the switch, or worn flash |

A card that accepts commands but silently drops what is written is not
read-only for the kernel: it shows up as I/O errors, or files that come back
after deleting them. The repair of a card (22-repair.md) tells that apart by
writing and reading back, and erases the card.
