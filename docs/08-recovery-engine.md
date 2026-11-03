# 08 — Recovery engine

Migrated from Big-Mount 2.6 (`drive-diag.sh`, `drive-copy.sh`,
`drive-recovery.sh`); behaviour unchanged.

## Health, from what is already known

`bsr_drive_health` and `bsr_ds_level` read only the kernel log of this boot
(timeouts, I/O errors, link slow-downs, USB resets), udev and what UDisks2
keeps of SMART/NVMe health without a password. The drive itself is not read.
`--cli diagnose DISK --smart` adds `smartctl -H -A -i -l selftest` through
the helper (password asked; the self-test log is only read, a self-test is
never started). The verdict is one of *Healthy,
Good, Poor, Critical* with the facts behind it and their basis (log, SMART).

## Choosing a method

`--cli methods TARGET` lists what can be done and recommends one:

| Situation | Recommended |
| --- | --- |
| healthy volume | `quick`: list what exists, copy what you choose |
| drive at risk, volume readable | `copy`: copy what matters first, no full scan |
| drive at risk, volume not readable, or a whole disk at risk | `image` (GNU ddrescue), then work on the image |
| an image file | `deep`: PhotoRec on it, it touches no disk |
| an SSD with TRIM | a note: deleted files may be gone for good |

Repair is never a method. No `fsck`, `ntfsfix`, `btrfs check --repair`,
`testdisk` *write*, or partition table rewrite is run, offered or needed to
get files out. When a person wants to repair later, the advice is: image or
copy first.

## Mounting for reading

`--cli mount DEV --read-only` mounts through UDisks2 with
`ro,noatime,nosuid,nodev,noexec`, and for ext3/ext4 `noload` (the journal is
not replayed). `--protect` also sets the block device read-only
(`blockdev --setro`, through the helper) so that no driver writes to it. A
drive at risk is never mounted with writing: `--read-write` is refused.

## Tools

| Method | Tool | Writes to | Privilege |
| --- | --- | --- | --- |
| copy | rsync | another filesystem, checked to be on another physical disk | user |
| image | GNU ddrescue (`--idirect --no-scrape`; with retries, `--retry-passes=N`, N ≤ 5) | an image file + mapfile, never on the disk being read | helper |
| partitions | TestDisk `/list` and `partition_gpt\|i386,analyze`; nothing written | nothing | helper |
| carve | PhotoRec, by categories, on an image (or on a device the user can read; otherwise the advice is to image it first) | another folder, not inside the source | user |
| scan | a list of the files that exist, by type | the job folder | user |
| salvage | GNU ddrescue on each file a copy left out (`--cli salvage COPY_ID`): good areas first, a map per file in the job folder, zeros where nothing could be read; complete files to their place, the others to *Partly recovered files - DATE* with `unreadable areas.txt` | the copy's destination | user |
| check-files | `integrity.py`: the structure of each file a search found (complete, truncated, damaged, unknown), at the end of a search and with `--cli check-files ID` | the job folder | user |
| manifest | SHA-256 of what a copy, salvage or image wrote (`--cli manifest ID`), checked with `sha256sum -c` | the job folder or `--output` | user |

The mapfile of ddrescue is written through the helper next to the image, with a
backup (`MAP.bak`): a resumed image never reads a good area twice. ddrescue
saves it every 5 s (`--mapfile-interval=5`; by default it waits 30 s to
5 min), so the progress and the map of the image page are current.
`--cli map ID` reduces it to cells for that page and for the terminal. Before
starting, the destination of an image must not be on the disk being read.

## Words that never mean the same thing

| Word | `result_kind` | Meaning |
| --- | --- | --- |
| **Found** | `existing-files` | a file listed by `scan` |
| **Candidate** | `carved-candidates` | a file PhotoRec reconstructed from content: name lost, may be incomplete |
| **Recovered** | `copied-files` | a file written to the destination and renamed after `fsync` |
| **Verified** | `verify_result: ok` | the copy was compared with the source (`metadata` or `full` checksum) and matched |
| **Partly recovered** | `salvaged-files`, `partial` | a file saved by salvage with areas that could not be read (zeros there, listed by byte range) |

## Physical damage

Software cannot fix a head crash, a dead controller, damaged NAND or broken
firmware. For a drive at risk the advice (`bsr_ds_advice`) is to copy what
matters first, without repairs, and, when the data is very important and
cannot be replaced, to consider a data recovery professional before insisting.
An image starts with one pass and no retries (`--no-scrape`); retries are an
explicit choice.
