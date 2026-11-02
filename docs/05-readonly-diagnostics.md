# 05 — Why a device cannot be written to

`bsr_diagnose_write` (`lib.sh`) decides one cause; `bsr_cause_text` (`cli.sh`)
explains it. The order goes from the hardware up, so a restriction is never
taken for damage and damage is never hidden behind a restriction.

| Cause | Evidence | What is said or offered |
| --- | --- | --- |
| `hw-readonly` | the block device is read-only (`ro` in sysfs: lock switch, worn flash) | the switch; copy the files soon if there is none |
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
