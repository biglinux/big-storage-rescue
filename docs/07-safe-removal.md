# 07 — Unmounting and safe removal

`bsr_remove_core` (`cli.sh`), modes:

| Mode | Command | Does |
| --- | --- | --- |
| `unmount` | `--unmount TARGET`, `--cli unmount VOLUME` | one filesystem |
| `drive` | `--safe-remove --no-power-off`, `--cli unmount DISK` | every filesystem of the drive |
| `remove` | `--safe-remove TARGET`, `--gui-remove`, `--cli safe-remove` | every filesystem, then locks its open LUKS volumes and powers a removable drive off |

Sequence, with the checks that make it safe:

1. Refused (exit 4) when the drive holds the running system (`/`, `/boot`,
   `/home`, `/usr`, `/var`, swap in use…): `bsr_system_use`.
2. Services that would be stopped are listed first (exit 9); they are stopped
   only after the person agrees (`--assume-yes` in scripts).
3. Stacked devices are unmounted top-down (LVM and LUKS before their partition)
   through UDisks2, as the user: polkit decides, never `sudo umount`. FUSE
   daemons (ntfs-3g) are waited for: the data is written when they exit.
4. Before each step the disk sequence number is compared: a drive unplugged and
   replaced by another under the same name stops everything (`RM_GONE`).
5. Nothing may have been mounted again meanwhile.
6. Internal disks are unmounted, never powered off. A removable drive is powered
   off through UDisks2 (a few attempts while udev settles); a drive that cannot
   be powered off is reported as such (exit 7) and is safe to unplug.
7. "Safe to disconnect" is said only after all of this was verified.

A lock per drive (`$XDG_RUNTIME_DIR/big-storage-rescue-drive-NAME.lock`) keeps
a double click on the Dolphin action, or the window and a terminal, from
removing the same drive twice (exit 10).

**Never**: `umount -l` (lazy) or `-f` (forced) as a default, killing processes,
unmounting the partitions of the running system, or powering off an internal
disk. A partition that Big-Mount mounted at boot is unmounted like any other
when the person asks; Big-Mount is not restarted or reconfigured.
