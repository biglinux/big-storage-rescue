# 04 — Device detection

Migrated unchanged from Big-Mount 2.6 (`drive-detect.sh`, `bsr_facts` and
`bsr_resolve` in `lib.sh`); only names changed.

- **One snapshot**: one `lsblk -P -b -p -o …` call, parsed once into
  `DV["DEV|KEY"]` (`bsr_dv_scan`). The filesystem columns call `statvfs`, which
  can hang on a mount stuck on a bad sector, so they get 6 s; without them the
  list is still made and marked partial. The device itself is never read to be
  listed: a failing disk must not be touched for that.
- **Disk, partition, controller**: an NVMe controller (`/dev/nvme0`) is not a
  storage device; its namespaces (`/dev/nvme0n1`) are, and their partitions
  (`nvme0n1p1`). `bsr_dv_is_top`, `bsr_dv_children` build the tree from
  `PKNAME`; a device under several parents (LVM on two disks, md RAID) appears
  once and keeps all its parents in `DV_PARENTS`.
- **Stable identity**: the window follows a drive by `bsr_dv_stable_id` (serial,
  else the UUID of a filesystem on it, else name and size), never by `/dev/sdX`
  alone, which another device can take after a reconnection. Before every
  operation that cannot be undone, the disk sequence number
  (`/sys/block/X/diskseq`) is read again (`bsr_diskseq`): a different number
  means another device, and the operation stops.
- **Stacks**: LUKS (`crypto_LUKS` → `dm-crypt` holder), LVM (`LVM2_member` →
  `lvm`), md RAID and multi-device Btrfs (`bsr_dv_multi_btrfs`) are shown as
  such; a locked LUKS volume is *detected*, not *accessible*.
- **Kinds**: `bsr_dv_kind` tells HDD, SSD (`ROTA`), NVMe, USB, SD card, eMMC,
  optical drive and disk image (loop) apart, from the transport and, for
  `mmcblk`, the MMC type in sysfs (`SD` is a card, `MMC` is soldered eMMC).
  Whether a drive is external comes from `RM`, `HOTPLUG` and the transport.
- **Targets**: every command takes a device, a folder inside a mounted device or
  a filesystem UUID (`bsr_drive_resolve`). An empty target is an error, never
  the current folder. A UUID shared by two devices is ambiguous and refused.
- **Filesystems**: a recognized signature is not support. `bsr_dv_fs_supported`
  looks for a driver (`/proc/filesystems`, a `mount.TYPE` helper, a kernel
  module); without one the volume is shown as detected but not openable, and
  `--cli methods` offers only what works on the raw device (an image, a search
  by content), each with the reason when it is not available.

Tests: `tests/drive-tests.sh` (fixtures of NVMe, LUKS, LVM, multi-device Btrfs,
SD, eMMC, loop) and `tests/drive-integration.sh` (real loop devices).
