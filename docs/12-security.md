# 12 — Security

## Privileges

Everything runs as the logged-in user. The window and the dialogs refuse to
run as root. What needs more goes through:

| Path | Who decides | For |
| --- | --- | --- |
| UDisks2 (D-Bus, `udisksctl`, `gdbus`) | polkit, UDisks2's own actions | mount, unmount, unlock, lock, power off |
| `pkexec /usr/lib/big-storage-rescue/bsr-holders MOUNTPOINT` | `org.biglinux.big-storage-rescue.inspect-processes` (`auth_admin_keep`) | `lsof` of every user, one mount point of a local block device, never the running system |
| `pkexec /usr/lib/big-storage-rescue/bsr-drive-helper image DEV …` | `org.biglinux.big-storage-rescue.image` (`auth_admin`, asked every time; picked by `exec.argv1`) | `image` (ddrescue): a raw copy of a whole drive holds the files of every user |
| `pkexec /usr/lib/big-storage-rescue/bsr-drive-helper VERB DEV …` | `org.biglinux.big-storage-rescue.drive-helper` (`auth_admin_keep`) | `protect`/`unprotect` (blockdev), `smart` (`smartctl -H -A -i -l selftest`: reads, never starts a test), `partitions` (TestDisk, read-only commands) |

No daemon, no setuid file, no systemd unit, nothing permanent. Both helpers
get a clean environment from pkexec and treat every argument as untrusted:
device names must match `^/dev/[A-Za-z0-9._/:+-]+$` without `..` and resolve
to a block device.

The drives of the running system are refused for protect, unprotect and
image. A loop device is imaged only when the file behind it is the user's.

The files of an image (image, map, map.bak) are opened by a small
`python3 -I` step:
- it walks every folder from `/` without following a link (`O_PATH|O_NOFOLLOW`);
- the last folder must be the user's (`PKEXEC_UID`);
- it opens each file as a path first, so a device or a FIFO is never really opened;
- each file must be a regular file with one name that belongs to the user, or is created with `O_EXCL`;
- from then on only `/proc/PID/fd/N` is used, so a link swapped in afterwards changes nothing;
- what it created is removed if it refuses.

A map over 64 MiB, or with a line that is not map grammar, is not used.
protect, unprotect and image take the disk sequence number and check it right
before acting. The image is never written to the disk being read.

## What is never done to the source

No write is issued by this program to a drive it is rescuing from: no format,
partition table change, filesystem repair (`fsck`, `ntfsfix`, `btrfs check
--repair`), overwrite of sectors, `TRIM`, forced or lazy unmount, or mount
with writing of a drive at risk. Devices are mounted read-only by default and
can be blocked at the block layer (`protect`).

## Secure Erase

Secure Erase, Sanitize, formatting and the initialization of disks destroy
data; they are not recovery. They were part of Big-Mount 2.5–2.6
(`drive-erase.sh`, `bm_erase_*`, the *Advanced maintenance* page, the
`--secure-erase` option) and are **not** part of Big Storage Rescue: not
installed, not offered, not reachable by any option (`tests/lib-tests.sh`
checks it). Their code, reviews and tests remain in the history of both
repositories (last at Big-Mount `40612ab`) and in
`big-mount-history/14-drive-health-and-secure-erase.md`. If destructive
maintenance is ever wanted again, it belongs in a separate tool with its own
rules.

## Untrusted data

Volume labels, model names, file names and process names come from devices or
other users. They are passed as separate arguments (never `eval`, never a shell
string), escaped in JSON (`bsr_js`), stripped of control characters before a
terminal, and given to the dialogs as data, never as markup. Translations are
data too (`shopt -s noexpand_translation`).

## Identity of a device

`/dev/sdX` is never trusted to be the same device across time: before every
unmount, lock, power off or helper call the disk sequence number is compared
with the one that was examined; a mismatch stops the operation.

Files found by content are untrusted:
- `integrity.py` reads them with bounded reads, never follows a link, never decodes or runs anything, and never lets a length read from a file decide how much memory is taken;
- thumbnails are refused above 100 megapixels;
- numbers read back from a job's `state.env` are used only if they are digits.

## Passwords

LUKS passphrases go from the window straight to UDisks2 over D-Bus, or are
asked by `udisksctl` in the terminal: never in arguments, files, logs or
reports. Nothing tries to get around encryption.

## Files

Job folders are mode 700, temporary files are created with `mktemp` in the
private runtime folder (also the kept history of earlier starts of each
internal drive, 18-system-and-history-checks.md), reports anonymize serial numbers, UUIDs, labels, the
home folder and the user name on request (`--anonymize`), and an existing
report is replaced only with `--replace`, after the new one is complete.
