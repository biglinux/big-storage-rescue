# 18 — The running system, and what a drive went through before

Added on 2026-11-02, after the split, from a review of `big-diagnostico.sh`:
a general analysis and repair script for BigLinux machines that checks
hardware, kernel, drivers, boot, services, packages and storage, and repairs
what it can. Big Storage Rescue is a rescue tool, so only its storage checks
were relevant, and only those that read without changing anything.

## What was taken, and how

| From the script | In Big Storage Rescue | Where |
| --- | --- | --- |
| `btrfs device stats` (needs root) | the same counters, read as the user from `/sys/fs/btrfs/UUID/devinfo/*/error_stats`; ext4 also gets its `errors_count` | `bsr_fs_errors`, `bsr_drive_fs_errors` (lib.sh) |
| SATA bus errors (`exception`, `SError`) and I/O errors in the kernel log of the last 7 days | the kernel log of earlier starts of the computer, for internal drives only, attributed by port **and** identity (below) | `bsr_drive_history` (lib.sh) |
| last SMART self-test failed | the helper also reads `smartctl -l selftest` (a log is read; a test is never started) | `bsr-drive-helper smart`, `bsr_ds_smart_parse` |
| disk full | free space of the filesystems of the running system | `bsr_sc_space` (system-check.sh) |
| Btrfs with little unallocated space | the same, from `/sys/fs/btrfs/UUID/allocation`, critical when metadata is also full | `bsr_sc_btrfs` |
| partitions left mounted by os-prober | reported, with the command an administrator can run | `bsr_sc_osprober` |

They appear in the drive manager (`--cli diagnose`, the *Health* page of the
window), in `--diagnose` and in `--doctor`. New reasons of the health level:
`past-errors` and `fs-errors` (attention) and `selftest-failed` (critical).

## Only where they mean something

**The running system.** Free space and Btrfs room are asked only of the
filesystems mounted at the system mount points (`/`, `/home`, `/boot`, `/var`,
… — `BSR_SYSTEM_MOUNTS`), so only the drive the computer started from gets
them. A full USB stick or a full backup disk is the business of its owner,
not a fault. os-prober leftovers are the exception: they are shown on
whichever drive holds the partition, because that partition is the one that
cannot be removed or checked.

**Earlier starts: internal drives only.** A message of an earlier start says
`ata2` or `nvme0` and maybe `sdb`, but nothing proves that it was the same
drive as now. So:

- only ATA and NVMe ports are read: an internal drive stays on its port;
- an earlier start counts only if the kernel found, on that port, the same
  model and firmware (`ata2.00: ATA-10: WDC WD10SPZX-24Z10T0, 01.01A01`) or
  the same PCI function (`nvme nvme0: pci function 0000:09:00.0`) as in this
  start. A start whose beginning was rotated out of the journal is skipped;
- USB drives come and go, and their port and `sdX` names are reused: for them
  only this start is read, as before;
- at most the last 5 earlier starts, none older than 30 days;
- a problem is any read failure (`UNC`, medium error), or three messages or
  more: one stray `failed command` at resume is not a fault. Connection errors
  only (`ICRC`, slowed link) point at the cable.

Earlier starts do not change, so what was found is kept for this start in the
private runtime folder (`history-BOOT-PORT-DISKSEQ`): another drive put on the
port has another disk sequence number and is read on its own.

**The filesystem counters** are kept by the filesystem on the drive, for any
mounted Btrfs or ext4, internal or external. They count since the filesystem
was created or since an administrator reset them (`btrfs device stats -z`,
`e2fsck`), and the advice says so.

**The notifier** announces drives with problems at login once per start. A
drive whose only reasons are `past-errors` or `fs-errors` is not announced:
those were already there at the last login, and would come back at every
start. They are shown in the window.

## What was left out, and why

| From the script | Why not here |
| --- | --- |
| GPU hangs, kernel parameters, microcode, DKMS, drivers, GRUB, systemd services, coredumps, udev groups, packages, network, processes, firewall, journal size | not storage: they belong to a system repair tool |
| zeroing a disk to force sector reallocation | destructive; not a rescue (see 12-security.md) |
| `fsck` at the next boot, Btrfs `scrub` and `balance` | they write, and a scrub reads the whole drive, which wears a failing one. `balance` is only *named* in the advice for a healthy system drive, for an administrator to run |
| a long SMART self-test | it reads the whole surface of a drive that may be failing; the result of one already run is read |
| unmounting os-prober leftovers | an unmount of a mount Big Storage Rescue did not make; the command is shown instead |
| a Btrfs rescue mount (`rescue=ignoredatacsums`) | useful for a filesystem whose checksum tree is damaged, but it needs a new privileged mount in the helper; worth its own review |
| journal of 7 days for every drive | names are reused (above) |

## Safety and cost

Everything reads `/sys`, the mount table, the journal and the free space
(statfs) of the system mounts, as the user. statfs is asked of those mounts
only, and with a limit of 5 seconds: a mount whose driver is stuck — FUSE on a
failing disk, a share that went away — hangs whoever asks it. Asking every
mount at once (`findmnt -o SIZE,AVAIL`) did hang `--doctor` on the development
machine while an NTFS volume of a failing disk was mounted; now it takes 0.9 s
there. Nothing is written but the cache file, nothing is run
on behalf of the person, and no new privileged operation was added: the
helper's `smart` verb only asks `smartctl` for one more log.

Cost, on the development machine with 6 drives (4 internal): the first read
of the history is about 25 ms per internal drive, later ones 1–2 ms;
`--cli list --json` went from about 345 ms to about 358 ms (eight runs each, warm cache);
`--doctor` takes 0.6 s.

## Tests

`tests/lib-tests.sh` (37 checks): counters of Btrfs and ext4 from a scratch
`/sys/fs`, each filesystem once per drive; earlier starts from a stand-in
journal (identity on the port, another drive on the port, a start older than
30 days, this start never read as an earlier one, the cache, USB, cable
errors, a stray message, NVMe identity); the running system from a stand-in
mount table and `/sys/fs` (full, low, a large disk that is fine, `/boot`,
another drive, Btrfs room and metadata, os-prober, statfs asked of the
system mounts only, a system mount that does not answer).
`tests/drive-tests.sh` (13): the new reasons and their words, the self-test
log, the notifier staying quiet, and the JSON of a diagnosis.
`tests/gui-tests.py` (2): the *running system* group and the messages of
earlier starts appear when the engine reports them, and not otherwise.
