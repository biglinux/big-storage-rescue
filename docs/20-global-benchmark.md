# 20 — Global benchmark: data-recovery tools and what Big Storage Rescue could learn from them

Date: 2026-11-02. A research document, not a plan of record. Nothing here was
implemented, run against a disk or installed when it was written. Since then
(see [21](21-world-class-progress.md)), several opportunities were built:
- per-file rescue with ddrescue (salvage);
- the damage map;
- the structural check of carved files;
- SHA-256 manifests.

## 0. Method and conventions

- Facts about other tools come from their manuals, man pages, repositories and
  changelogs. Each one carries a source tag `[Sn]`, listed in §9. A claim we
  could not check is marked **not verified**.
- Commercial products are described only by what they do in public, from the
  vendor's own pages. Those are **vendor claims**: nothing was tested.
- This document does not rank tools as "better" or "worse". No comparable tests
  were run. Where Big Storage Rescue (BSR) is said to "already do" something,
  that means the feature exists in this repository (docs 03, 05, 08, 09, 12, 17
  and 18, and the code they point to). It does not mean it matches the other
  tool in quality.
- Package availability was checked read-only on 2026-11-02 with `pacman -Si`
  against the repositories configured on the development machine
  (`biglinux-priority`, `core`, `extra`, `multilib`, `biglinux-stable`,
  `biglinux-extra`, `community-*`). The AUR was not checked. Vanilla Arch may
  differ (for example, `zfs-utils` is in these repos: **not verified** for Arch
  `extra`).
- Priorities: **P0** means safety, integrity or a critical gap. **P1** means
  recovery or reliability, and is important. **P2** means advanced, innovative
  or optional.

## 1. Baseline: what BSR is today

| Area | BSR today (where documented) |
| --- | --- |
| Architecture | Bash engine plus a GTK 4/libadwaita window over `--cli … --json`. Privileges go through UDisks2/polkit and two pkexec helpers (`bsr-holders`, `bsr-drive-helper`). There is no daemon (03, 12) |
| Health | Drive health from UDisks2, kernel log of this boot, earlier boots for internal ATA/NVMe drives (identity-checked), Btrfs/ext4 error counters, and `smartctl -H -A -i -l selftest` (text, parsed) through the helper. A self-test is never started (08, 18) |
| Diagnosis | One cause for "why can't I write here", from the hardware up. Safe fixes only (05) |
| Copy | `rsync -rlt --fsync`, per-file resume, files stuck for 90 s are deferred, more than 100 deferred stops the job, verify `basic\|metadata\|full` (09) |
| Image | GNU ddrescue through the helper: `--idirect --no-scrape`, or `--idirect --retry-passes=N` (N ≤ 5). The mapfile is mirrored with `MAP.bak`, files are opened once through `/proc/self/fd`, and the image is never on the source disk (08, 12; `bsr-drive-helper` `image`) |
| Partitions | TestDisk `/list` and `partition_*,analyze`. Nothing is written (08) |
| Carving | PhotoRec by category, on an image or a readable device, with an indexed results browser (categories, thumbnails; `gui/pages/results.py`) |
| Vocabulary | *Found / Candidate / Recovered / Verified* never mean the same thing (08) |
| Safety | Never repairs, formats or TRIMs. Mounts read-only (`noload` for ext3/4), with optional `blockdev --setro`. The same physical disk is refused as a destination through LUKS/LVM/partitions. Identity is checked by diskseq. Reports can be anonymized (05, 08, 09, 12) |
| Known limits (README) | Resume works per file. A partially readable file is not kept. XFS/Btrfs log replay cannot be avoided through UDisks2. Cancel waits for a blocked kernel read. Owners are not kept. FAT32 has a 4 GiB limit. Not validated on LVM/RAID/SD/eMMC hardware |

Not found in the code: computing SHA-256 of results, attaching a disk image
read-only from inside BSR, parsing the ddrescue mapfile beyond checking that it
is complete, `smartctl -j`, and Sleuth Kit.

## 2. Imaging failing media

### 2.1 GNU ddrescue (the engine BSR already uses)

**Version.** 1.30, released 2026-01-04. The manual is dated 2026-01-01 [S1][S2].
The repos carry `ddrescue 1.30-2` (GPL-2.0-or-later).

**Strategy** [S1][S2]:

1. Copying: up to 4 passes over the non-tried areas, skipping on error or slow
   reads. Passes alternate direction unless `-u`. In 1.30, pass 2 copies only
   blocks next to finished ones, so a bad area is outlined as a whole.
2. Trimming: reads the edges of failed blocks.
3. Sweeping: new in 1.30, replacing the old pass 5. It reads the skipped
   non-tried areas once, without skipping.
4. Scraping: sector by sector.
5. Retrying: `-r N` passes.

1.30 also says automatic recovery from a dead head is much better. A 1 TB drive
with 1 of 4 heads dead went from 3,782,794 to 283 read errors [S2].

**Options relevant to BSR** (long names quoted from the manual [S1]):

| Option | Meaning | BSR today |
| --- | --- | --- |
| `-d, --idirect` | `O_DIRECT` on the input, bypassing the kernel cache | used |
| `-n, --no-scrape` | skip scraping | first run |
| `-r, --retry-passes=N` | retry bad sectors N times | ≤ 5, on request |
| `-R, --reverse` | reverse the direction of all passes | no |
| `--cpass=range` | which copying passes run (`0` = none) | no |
| `-K, --skip-size=[initial][,max]` | skip after an error or slow read. Default initial is size/32768, at least 64 KiB, and max is 1% of the size | default |
| `-a, --min-read-rate=bytes` | a slower read counts as slow (`0` = auto: average/10) | no |
| `--max-slow-reads=n` | give up after n slow reads in passes 1–2 (needs `-a`) | no |
| `-T, --timeout=interval` | give up when no read has succeeded for this long | no |
| `-E, --max-error-rate=bytes` | give up above this rate of failed reads per second | no |
| `-e, --max-bad-areas=[+]n` | give up above n bad areas (`+` counts only new ones) | no |
| `-X, --max-read-errors=n` | give up after n read errors (exit status 1) | no |
| `-N, --no-sweep` | skip sweeping. "May be useful when the drive has a dead head." In 1.30 `-N` moved here from `--no-trim` | no |
| `-m, --domain-mapfile=file` | restrict the rescue to the finished blocks of another mapfile | no |
| `-i/-s` (`--input-position`, `--size`) | rescue a byte range only | no |
| `-S, --sparse`, `-p, --preallocate` | output allocation | no |
| `--log-events/--log-rates/--log-reads=file` | logs | no |
| `--mapfile-interval=[save][,sync]` | how often the map is saved and synced (sync default 5 min) | default (the helper also mirrors every 2 s) |
| `--command-mode` | read `c pos size`, `s pos size`, `u`, `f`, `q` from stdin and copy on demand | no |
| `-F, --fill-mode`, `-G, --generate-mode` | fill bad areas with a marker, or rebuild an approximate map | no |

Note on 1.30 compatibility: BSR passes long options only, so the move of `-N`
does not affect it. The helper's `whole_map` regex already accepts `%` (the
sweeping state) in the status line. Any new option should keep using long names.

**Mapfile** [S1]. It has comment lines, then a status line
`current_pos current_status current_pass`, then one line per block:
`pos size status`. Block status: `?` non-tried, `*` non-trimmed, `/`
non-scraped, `-` bad sector, `+` finished. Current status adds `%` (sweeping),
`F` (filling), `G` (generating) and `+` (finished). "Without a mapfile,
ddrescue can't resume a rescue, only reinitiate it" [S1].

**ddrescuelog** (local man page, 1.30 [S3]):

- `-t` show status, `-l types` list blocks, `-c` create a map from a sector
  list, `-D` done status, `-d` delete if done, `-A` annotate.
- `-p/-P` compare, `-x/-y/-z` xor/and/or of maps, `-n` invert, `-C` complete,
  `-L` loose domain, `-b` block size.
- `-H` make test (new, work in progress) [S2].

**Failing media.** ddrescue is the reference open-source imager. Its limits are
by design: it reads through the kernel block layer, so a hung command waits for
the kernel's SCSI/ATA timeouts and resets. It has no head map and no power
control. The manual's own rules: never rescue a partition mounted read/write,
"not even read-only" for imaging, and never repair a filesystem on a drive with
I/O errors [S1].

**Files.** ddrescue "copies data from one file or block device … to another"
[S1]. Its input may be a regular file. That is the basis of opportunity O3.

### 2.2 OpenSuperClone (successor of HDDSuperClone)

| | |
| --- | --- |
| What | Linux cloning/recovery tool "based on Scott Dwyer's HDDSuperClone" [S4] |
| License | GPLv2 per the README. GitHub reports `GPL-2.0`. "Or later" **not verified** [S4] |
| Status | Active. Last push 2026-10-27, `v2.6.0-alpha1` 2026-07-24, `v2.5.0` 2024-12-14 (GitHub API). The wiki is "work-in-progress" [S4] |
| Packages | Not in the configured repos. DEB/RPM releases, a live ISO, and a DKMS driver (OSCDriver) [S4] |
| Phases | 1 forward with skipping on errors, 2 backward, 3 forward with skipping on read **rate**, 4 forward without skipping, then trimming, dividing, scraping and retrying [S7] |
| Skipping | Per HDDSuperClone users, it adjusts itself to skip out of a bad head in about 7 read errors. There is a slow-read skip threshold (2000 ms default, phases 1–2). Slow-firmware drives can show "runaway skipping" (forum, not an official manual [S9]; **not verified** in OSC code) |
| Direct modes | Direct AHCI/IDE/USB. The drive is hidden from the OS and OSC talks to the controller ("circumvent the OS"). Described as preferred when possible [S6] |
| Virtual Disk Mode | A kernel driver presents the source as a block device. Every read through it is also copied to the destination, and later reads come from the destination. This lets DMDE, R-Studio or UFS Explorer pull only the data they need. Modes 1–5 range from all phases down to destination only, or zeros [S5] |
| Relay | Generic USB HID relay boards or YEPKIT YKUSH hubs power-cycle the drive (SATA needs 5 V and 12 V switched) [S8] |
| Results | OSCViewer (map viewer) and a speed graph (changelog) [S4] |

**For BSR.** Direct controller access, relay power cycling and a kernel module
are out of scope. They need a dedicated machine and root drivers, and they
conflict with BSR's "no driver, nothing permanent" rule (12).

Two ideas are transferable without them:

- On-demand imaging: ddrescue `--command-mode` plus a read-only NBD front end
  (`nbdkit 1.60.1` is in `extra`). This is opportunity O17, and it is
  experimental.
- Skipping on read rate: ddrescue `--min-read-rate`/`--max-slow-reads`.

### 2.3 ddrescueview

GPLv3, Object Pascal/Lazarus. 0.4.5, 2022-02-25. It shows a block grid
coloured by mapfile status, refreshes automatically, zooms to sector level, and
overlays domain mapfiles [S10]. It is not in the configured repos. **For BSR:**
the model for a native damage map (O5). Reading a mapfile is a 20-line parser.
There is no need to depend on Lazarus.

### 2.4 Clonezilla / Rescuezilla (imaging suites, not rescue tools)

- **Clonezilla.** `ocs-sr -rescue` means "try to skip bad sectors". It uses
  partclone/partimage/ntfsclone and falls back to `dd` (`-q1`). The man page
  does not mention ddrescue [S21]. Repos: `clonezilla 5.19.1` (GPL-2.0-only),
  `partclone 0.3.50` (GPL-2.0-or-later).
- **Rescuezilla.** GPL-3.0, a GUI compatible with Clonezilla images. It reads
  VDI/VMDK/VHDX/QCOW2/raw, md RAID and LVM, and has an Image Explorer (beta).
  Its page does not describe rescue of failing drives [S20].
- **For BSR.** These suites target backup and deployment of healthy disks.
  partclone can produce a ddrescue **domain mapfile** of used blocks, as the
  ddrescue manual says of "ddrutility or partclone" [S1]. That allows imaging
  only the allocated part of a partition (O18). The partclone flag itself is
  **not verified**: partclone is not installed here.

### 2.5 SystemRescue

Arch-based live system. 13.02, 2026-08-01, kernel 6.18 LTS [S22]. It ships
ddrescue, TestDisk, filesystem tools and rsync [S22]. **For BSR:** the natural
place to run BSR from when the failing drive holds the running system. A
"runs from a live USB" note or check in `--doctor` costs little. Being included
in SystemRescue is outside our control.

### 2.6 Commercial imagers (functional only, vendor claims)

| Product | Imaging of failing media, as described |
| --- | --- |
| UFS Explorer Professional | multi-pass imaging with passes, timeouts and block size; read-once mode; imaging from the filesystem map; entropy maps; E01/Ex01/AFF4/VMDK/VHDX/QCOW2. Linux build available [S38] |
| DMDE | image/clone with I/O error handling. Pro edition: resume logs for multi-pass, E01 read, I/O handler scripts. Windows, Linux, macOS, DOS [S39] |
| R-Studio (Linux) | disk imaging, sector map files "in internal and third-party formats" [S37] |
| Disk Drill | byte-to-byte backup that skips bad blocks first and retries them later, with a visual map of bad sectors. Windows/macOS only [S40] |
| PC-3000 Express | hardware: tester board, power supply with rail monitoring, vendor firmware utilities (disable heads, service area, defects), Data Extractor, "MR-Head Shift" [S41] |
| Stellar, EaseUS | not researched in detail: **not verified** |

Pattern across them: skip first, retry later, a visible map, and imaging of
used blocks only. BSR has the first. The others are O5 and O18.

## 3. Filesystem-level recovery and forensic browsing

### 3.1 TestDisk / PhotoRec / QPhotoRec

- **Version.** 7.2, 2024-02-22. Upstream says GPL v2+ [S11][S12]; the repo
  package says `GPL-3.0-or-later` (`testdisk 7.2-5`, which also ships
  `fidentify`). QPhotoRec is not in the configured repos (it is not built in
  this package).
- **TestDisk** finds lost partitions and volumes (MBR/GPT, BSD, Mac, Sun,
  LVM/LVM2, md, LUKS). It **undeletes** on FAT12/16/32, exFAT, NTFS and ext2,
  copies files from deleted partitions (FAT, exFAT, NTFS, ext2/3/4), and
  rebuilds FAT/NTFS boot sectors [S11].
- **PhotoRec** recognises more than 480 extensions in about 300 families. It
  works on raw images and **E01**. Its free-space mode knows FAT, NTFS, exFAT,
  ext2/3/4 and HFS+. It learns the block size from the superblock, or guesses
  it from the first files found. It recovers some fragmented files on a second
  look. It handles ReiserFS tails poorly, and names are always lost [S12].
- **BSR today:** TestDisk read-only analysis, and PhotoRec by category with an
  indexed browser.
- **Could add:**
  - TestDisk's undelete is interactive. Scripting it with `/cmd` for undelete is
    **not verified**, so Sleuth Kit is the cleaner backend for browsing deleted
    files (O7).
  - PhotoRec's E01 input matters only if O15 is done.
  - `fidentify` can check carved files structurally (O9).

### 3.2 The Sleuth Kit (TSK)

- **Version.** 4.15.0, 2026-04-15: bounds checks, NTFS overflow fixes [S14].
  Repo: `sleuthkit 4.15.0-1` (license `CPL-1.0 GPL-2.0-or-later IPL-1.0`).
  It depends on `libewf`, so E01 can be read.
- **Filesystems** [S13]: NTFS, FAT, exFAT, APFS, UFS1/2, ext2/3/4, HFS,
  ISO 9660, YAFFS2. **Btrfs and XFS:** experimental in 4.13, then removed again
  in 4.14 ("does NOT have the experimental btrfs") [S14].
- **Volume systems:** DOS, BSD, Mac, Sun, GPT. LVM was added on non-Windows in
  4.12 [S14].
- **Images:** raw, E01 (libewf-legacy), VHD, VMDK, AFF [S13].
- **Tools used here:**
  - `fls -r -p -d` lists deleted entries with full paths [S15].
  - `icat -r` uses recovery techniques for a deleted file, `-s` adds slack and
    `-h` skips holes [S16].
  - `tsk_recover` recovers unallocated files by default (`-e` all, `-a`
    allocated only), limited to a volume with `-o` and a directory with `-d`
    [S17].
  - Also in the package: `mmls`, `fsstat`, `istat`, `ifind`, `ffind`,
    `blkls`, `fiwalk` (one XML record per file, with byte runs) and
    `tsk_loaddb`.
- **Strategy.** It parses metadata without the OS driver, so deleted and hidden
  entries show [S13]. It never writes.
- **Limits.**
  - Deleted content is recoverable only when the filesystem kept the pointers
    (§4).
  - Btrfs, XFS, F2FS, ZFS and ReFS are not supported.
  - Deleted-file support on APFS and HFS+ is **not verified**. The project calls
    its APFS support limited [S13].
- **License for BSR.** Mixed. CPL-1.0 and IPL-1.0 are listed by the FSF as
  GPL-incompatible [S44]. So call TSK as **separate programs** (aggregation),
  never link `libtsk` into BSR. Calling the binaries fits BSR's architecture
  anyway.

### 3.3 Autopsy

GUI over TSK. Apache-2.0, 4.23.1 of 2026-05-07. The README says it is "fully
tested only on Windows" [S19]. Java. Not in the configured repos. **For BSR:**
not an integration target. It is a case-based forensic workbench. Its useful
idea is the tree of a filesystem with deleted entries marked, which O7
reproduces with `fls`.

### 3.4 Dissect (Fox-IT)

A Python framework: `dissect.target` plus parsers for extfs, xfs, btrfs, ntfs,
fat, apfs, ffs, vmfs, squashfs and more. Volumes: LVM2, GPT, MBR
(`dissect.volume`). Encryption: LUKS1/2, BitLocker, VeraCrypt (`dissect.fve`).
Evidence containers: AD1, ASDF, EWF (`dissect.evidence`). AGPL-3.0 [S36].
Active (dissect 3.22, 2026-02). Only `python-dissect.cstruct` is in the repos.

**For BSR:** valuable as a reference for read-only parsing of XFS/Btrfs inside
images. But it is AGPL, not packaged, and has many PyPI dependencies. Its
deleted-file capabilities are **not verified**. P2 at most: an optional external
command, never imported.

### 3.5 ext3/ext4 undelete tools

- **extundelete** 0.2.4 (2013). It uses the journal to find an older copy of a
  deleted inode. ext3, and ext4 with a journal. No links, no xattrs [S23]. Not
  in the configured repos.
- **ext4magic** 0.3.2. Marked **abandoned**. The maintainers say current ext4
  filesystems are no longer compatible: "please do not use ext4magic" [S24].
  Not in the configured repos.
- **Why it is hard.** On ext4, whether the extent data in the inode is zeroed on
  delete depends on whether there is an extent tree. Index nodes are not zeroed
  [S25].
- **For BSR:** do not integrate either. Present ext4 undelete honestly: names
  through `fls -d`, content through carving (PhotoRec) or journal tools at the
  user's own risk.

### 3.6 XFS, Btrfs, NTFS helpers

- **xfs_undelete** (GPL-3.0, Tcl). It walks the inode B+trees and uses the
  extents XFS leaves in deleted inodes. Names and sizes are lost, and it handles
  at most 21 extents with 512-byte inodes. It opens the source read-only [S26].
  Not packaged. Not verified on XFS v5 (**not verified**).
- **btrfs restore** (btrfs-progs 7.1 in `core`). It salvages files from a
  damaged filesystem into a path without modifying it. `-t bytenr` reads an
  older root tree, `-l` lists roots, `-s` includes snapshots, `-i` ignores
  errors, `-D` is a dry run, `--path-regex` selects. Some data "might be …
  from older versions" [S27].
- **ntfsundelete** (ntfsprogs). Modes scan/undelete/copy. It "only ever reads
  from the NTFS Volume" [S43].
- **ntfscluster** lists the files that have data in a given range of sectors
  [S43]. This is the NTFS backend of O1.

### 3.7 OpenZFS

`zfs-utils 2.4.4` is in the configured repos (CDDL-1.0, kernel modules per
kernel).

- `zpool import -o readonly=on` imports read-only [S31]. `-N` imports without
  mounting, `-R` sets an altroot, and `-d dir` searches devices **or files** in
  a directory, which covers pools stored as image files [S30].
- `-F` rewinds by discarding the last transactions ("irretrievably lost"),
  `-n` with `-F` is a dry run, and `-X`/`-T txg` are "extremely hazardous" last
  resorts [S30].
- `zdb` is "not a general purpose tool". `-e -p path` works on exported pools,
  `-r dataset path dest` copies a file out, `-B` writes a backup stream from an
  objset ID without opening the dataset, and `-F/-X/-t` rewind for inspection
  [S32].

**For BSR:** read-only import of a pool from images is possible, but a rarity
on BigLinux desktops. Whether `-F` combined with `readonly=on` avoids
discarding anything is **not verified**, so BSR should never offer `-F/-X/-T`.
CDDL means command-line use only. P2.

## 4. Per-filesystem capability matrix (open-source, Linux)

"Undelete" means recovery that keeps the name and content through metadata.
Carving (PhotoRec) works on any filesystem but loses names, and it can scan
only free space where PhotoRec knows the filesystem [S12].

| FS | Read when damaged or unmountable (read-only) | Undelete by metadata | Map a bad sector to a file (for O1) | Notes for BSR |
| --- | --- | --- | --- | --- |
| ext2 | TSK [S13], `debugfs` (**not verified** here) | **Yes, often**: TestDisk [S11], TSK `fls -d`/`icat -r` [S15][S16] | TSK `ifind -d`, `fiwalk`; `filefrag -v` when mounted [S43] | best case |
| ext3 | TSK, read-only `noload` mount (BSR does) | names: TSK. Content: journal only (extundelete, 2013) [S23] | as ext2 | content mostly lost. Say so |
| ext4 | TSK, `noload` (BSR does) | names: `fls -d`. Content: rarely. Extents zeroed when there is no tree [S25]. ext4magic "do not use" [S24]. extundelete old [S23] | as ext2 | carving is the honest answer |
| Btrfs | `btrfs restore` (older roots `-t`) [S27]; `rescue=` mount (doc 18) | **no tool**. Older tree roots sometimes hold old versions [S27] | `btrfs inspect-internal logical-resolve` (**not verified** here) | CoW helps: offer `btrfs restore` on an image (O13) |
| XFS | `norecovery` mount (not on UDisks2's list: doc 08); libfsxfs, dissect.xfs | xfs_undelete: content without names, ≤ 21 extents [S26] | `xfs_db` (**not verified** here) | TSK support was withdrawn [S14] |
| NTFS | TSK [S13], ntfs-3g read-only | **Yes, often**: TestDisk [S11], ntfsundelete [S43], TSK | `ntfscluster` [S43], TSK `ifind`, `fiwalk` | best case on Windows disks |
| FAT12/16/32 | TSK, TestDisk | **Yes**: TestDisk [S11], TSK. Fragmented files usually lost once the chain is freed (**not verified** source) | TSK `ifind`, `fiwalk` | removable media |
| exFAT | TSK (since 4.2 per NEWS) [S14], TestDisk | **Yes**: TestDisk [S11]. TSK deleted support **not verified** | TSK | SD cards |
| F2FS | kernel driver only; no open forensic parser found (**not verified**) | none found | none found | carving the whole partition; TRIM likely (BSR already warns) |
| ZFS | `zpool import -o readonly=on -d DIR` [S30][S31]; `zdb -r`/`-B` [S32] | none (snapshots only). Rewind is destructive [S30] | `zdb` (expert) | CDDL; never `-F/-X` |
| APFS | TSK "limited" [S13]; libfsapfs (LGPL) [S45]; `apfsprogs` (apfsck) in repos | **not verified** (TSK, dissect.apfs) | **not verified** | rare on Linux desktops |
| HFS+ | TSK [S13]; kernel driver read-only when journaled (doc 05) | **not verified** in TSK. PhotoRec free-space mode supports HFS+ [S12] | **not verified** | |
| ReFS | no open-source reader found (**not verified**) | none | none | commercial only: R-Studio [S37], UFS Explorer [S38], DMDE [S39] (vendor claims) |

## 5. Health and identification

| Tool | Facts | BSR today | Opportunity |
| --- | --- | --- | --- |
| smartmontools 7.5 (2025-04-30 build; GPL) | `-j, --json[=cgiosuvy]`: JSON or YAML output (local man page). Also covers NVMe | text `-H -A -i -l selftest`, parsed by regex (`bsr_ds_smart_parse`) | O10: `smartctl -j -x` (or `-H -A -i -l selftest -l error`) parsed as JSON. More stable than text, and adds the error log and device statistics |
| nvme-cli 3.1 (GPL-2.0-or-later, built on libnvme) | `nvme smart-log`, `error-log`, `self-test-log`; `-o json`, `--output-format-version=2` with consistent field names (local man pages) | NVMe health through UDisks2 | optional detail through the helper. Keep UDisks2 as the default (no password) |

## 6. Containers and evidence formats

**libewf** (LGPL-3.0-or-later):

- Upstream labels itself "experimental". It reads and writes E01/Ex01/S01 and
  reads L01/Lx01 (delta files, write resume). The last pre-release is
  20260924 [S35].
- The repos carry `libewf 20140816-1`, the legacy stable line, also maintained
  as `libewf-legacy` [S35]. It ships `ewfacquire`, `ewfacquirestream`,
  `ewfverify`, `ewfmount` (FUSE), `ewfexport`, `ewfinfo` and `ewfrecover`.

**For BSR:** E01 matters to forensic users who receive images from others, and
for compressed images that carry embedded hashes. For rescue, raw image plus
ddrescue mapfile stays the right primary format: it can resume, and every tool
reads it. So:

- *Input:* `ewfmount` gives a raw view, so TSK and PhotoRec work on it. TSK and
  PhotoRec already read E01 directly [S12][S13]. P2.
- *Output:* convert the finished raw image with `ewfacquire` on the image file,
  never on the failing drive. Embedded MD5/SHA-1 are possible (**not verified**
  for SHA-256 in the 2014 line). P2.

LGPL-3.0 is compatible with GPL-3.0-or-later even for linking [S44]. Calling the
programs is simpler anyway.

## 7. Opportunity details (the ones that matter most)

### O1 — Which files are damaged (P0)

- **Problem.** A ddrescue image keeps unreadable areas as zeros. A file
  restored from the image (PhotoRec, a mount, TSK) looks complete but is
  silently corrupt. This is the same integrity gap the README states for files
  ("not saved in part"), moved one level down.
- **Idea.** Turn the mapfile's non-finished ranges (`ddrescuelog -l-/*?`
  [S3]) into a list of affected files:
  - for any TSK filesystem: `fiwalk` byte runs, or `ifind -d` per block then
    `ffind`;
  - NTFS: `ntfscluster` for a sector range [S43];
  - mounted ext4/XFS/Btrfs: `filefrag -v` (FIEMAP).

  Report "*N files touch unread areas*". In the results browser, mark those
  files *Damaged* rather than *Recovered*.
- **Prior art.** The ddrescue manual's fill-mode example writes a marker into
  bad areas and greps for it [S1]. That writes to the image. The mapping above
  does not.
- **Complexity:** medium (offset arithmetic: partition offset, block size).
- **Risk:** low. It reads only the image and the mapfile.
- **UX:** high (honest results).

### O2 — SHA-256 manifests (P0)

- Write `manifest.sha256` (the `sha256sum -c` format) for every completed copy
  job, every finished image, and every carved or exported set.
- Hash the **destination** only:
  - the copy: after `--fsync`, a second read of the destination, never of the
    failing source;
  - the image: at the end, or incrementally while it is written (**not
    verified** feasibility with ddrescue's out-of-order writes, so hash at the
    end).
- Store the hash in `report.json`. A later "check this rescue" verifies the
  manifest, catching a failing **destination** too.
- `b3sum` exists (`extra`), but SHA-256 is the interchange standard.
- Complexity low, risk low, UX medium.

### O3 — Per-file rescue with ddrescue (P0)

This answers README limitation 1 (a large file starts over, and a file with read
errors is not kept).

- **Idea.** When rsync fails on a file, or for files larger than a threshold,
  copy that file with `ddrescue --idirect --no-scrape SRC_FILE DEST.part
  MAP` as the **user**. The source is a regular file on the read-only mount
  [S1]. Then:
  - block-level resume from the per-file mapfile;
  - partial content saved, with the unread ranges listed (`ddrescuelog -l-`);
  - an optional retry pass later.
- **Result word.** A fifth result word, **Partial**, never shown as
  *Recovered* or *Verified*. The `.part` is kept beside a `.badranges.txt`.
- **No new privilege.** The user can already read the file.
- **Caveats:**
  - `O_DIRECT` on FUSE (ntfs-3g) or some drivers may be refused. Fall back to
    buffered reads with the kernel readahead window (**not verified** per
    driver).
  - The filesystem may itself return EIO for metadata, which this cannot help.
  - The manual's warning against mounted partitions [S1] concerns imaging a
    partition. Here the mount is read-only, `noload`, and optionally `--setro`
    (doc 08).
  - FAT32 destination: still the 4 GiB limit.
- **Complexity:** medium (a new step in `drive-copy.sh`, mapfile per file,
  pause/resume).
- **Risk:** medium (the interaction with the 90 s stuck-file rule).
- **UX:** high.

### O4 — Stop conditions and dead-head hints for images (P1)

- Offer conservative "stop if the drive is collapsing" limits, so a dying drive
  pauses for a human decision instead of grinding:
  - `--timeout` (for example 10 min without a good read);
  - `--max-error-rate`;
  - `-X/--max-read-errors` on retry runs only.
- These mirror the copy rule "more than 100 set aside stops the job" (doc 09).
  A stop is resumable from the mapfile.
- Read a sudden rate collapse in `--log-rates` as a hint, never a diagnosis,
  that a head may be failing. Suggest `--no-sweep` [S1] and a professional.
- Require `ddrescue >= 1.30` in `--doctor` for the improved dead-head handling
  [S2].

### O5 — Damage map from the mapfile (P1)

- A native widget: a grid or strip coloured by `+ ? * / -`, refreshed from the
  mirrored map (the helper already rewrites it every 2 s). Clicking a cell gives
  byte range and status, and with O1, the files there.
- Same data in the terminal (`--cli status ID --map`) and in reports.
- Prior art: ddrescueview [S10], OSCViewer [S4], Disk Drill [S40].
- Complexity low to medium, risk none (reads a file), UX high.

### O6 — Open an image read-only (P1, precondition of O7/O12/O13)

- "Open image": `udisksctl loop-setup -r` (or `losetup -r` [S43]), partitions
  scanned, every mount read-only.
- Identity is the backing file and inode, recorded in the job.
- This removes the "same disk" checks entirely: the image is on another disk by
  construction.

### O7 — Browse and recover deleted files from images with TSK (P1)

- **Steps.** `mmls`, then `fsstat`, then `fls -r -p -d` [S15], shown in the
  existing results browser with a *Deleted* badge. Export with `icat -r`
  [S16], or `tsk_recover` for a whole volume [S17].
- **Gating.** Only for the filesystems in §4 where it means something (ext2,
  NTFS, FAT, exFAT; names only for ext3/ext4). Use the capability matrix to say
  in plain words what to expect per filesystem.
- **Inputs.** Images only (raw, E01) or a protected device, never a writable
  mount.
- **License.** Call the binaries; do not link (§3.2).
- Complexity medium, risk low (read-only), UX high for the common
  "I deleted it from the USB stick" case.

### O8 — Validate carved candidates structurally (P1)

- Run cheap checks per category, in a sandboxed subprocess with a timeout,
  never as root:
  - `fidentify` (same signatures as PhotoRec);
  - images: Pillow `verify()`, which is already near the thumbnail code;
  - PDF: `qpdf --check`;
  - ZIP/Office: `7z t` or `unzip -t`;
  - audio/video: `ffprobe`;
  - FLAC: `flac -t`.
- Tag each candidate *Opens*, *Damaged* or *Unknown*. Sort and filter by it.
  Candidates stay candidates.
- All the tools are in the repos (`testdisk`, `python-pillow`, `qpdf`, `7zip`,
  `unzip`, `ffmpeg`, `flac`).
- Risk: parsers of untrusted files. Mitigate with a timeout, as the user, and
  optionally under `systemd-run --user` with limits (**not verified**
  available on every target).

### O9 — `fidentify` and size sanity for PhotoRec results (P1, part of O8)

PhotoRec truncates files to the size in their header and drops files smaller
than their header [S12]. Show that in the browser ("size from header" against
"stopped at end of data") where PhotoRec's report allows it (**not verified**
which fields `report.xml` carries).

### O10 — `smartctl -j` (P1)

Switch the helper to JSON output (§5). The parser becomes simpler, and the
error log, device statistics and NVMe fields are added without regex. Keep the
same verbs and the same "never start a test" rule.

### O12 — Read-only LVM from images (P1); md RAID virtual assembly (P2)

- **LVM** (single image, the common laptop layout):
  - attach read-only (O6);
  - run `vgchange -ay --readonly`, or activate the LVs with permission `r`.
    `--readonly` "prevents the command from making changes, including
    activation and metadata updates" [S43]. It needs checking whether
    activation itself is blocked (then use `lvchange -p r` on a dm table):
    **not verified**;
  - handle the **duplicate PV UUID** when the original disk is also attached
    (`--devices`/a devices file; **not verified** on BigLinux defaults).
- **md RAID** from several member images:
  - use read-only loops plus `mdadm --assemble --readonly` [S43];
  - for anything that might write (wrong order, `--create` experiments), use
    the Linux RAID wiki's overlay technique (dm snapshots over sparse files)
    [S42];
  - never `--create` on the members themselves.
- Hardware validation is still pending for BSR (README), so this is P2 behind
  an "advanced" switch.

### O13 — Btrfs and XFS without log replay, on images (P1)

The README says XFS/Btrfs with an unclean log cannot be mounted through UDisks2
without replaying it. On a **read-only loop of an image**, the helper could
mount with `norecovery` (XFS) or `rescue=nologreplay`/`usebackuproot` (Btrfs).
Doc 18 already lists `rescue=ignoredatacsums` as worth its own review. It could
also offer `btrfs restore -D` then `btrfs restore` [S27]. This needs a new
helper verb with the same argument checks (12).

### O14 — ZFS pools from images, read-only (P2)

`zpool import -d DIR -o readonly=on -N -R /run/…`, then mount the datasets
read-only [S30][S31]. Never `-F/-X/-T`. Only if `zfs-utils` is installed.

### O15 — E01 in and out (P2)

See §6. Input through TSK/PhotoRec directly or `ewfmount`. Output as a
conversion of a finished raw image with `ewfacquire`.

### O16 — Dissect as an optional external reader (P2, low)

See §3.4. AGPL and pip-only. Document it, do not ship it.

### O17 — On-demand imaging, a virtual disk without a kernel module (P2)

- **Idea.** Serve a read-only NBD device. Reads of finished blocks come from
  the image. Reads of unread blocks are fetched once through `ddrescue
  --command-mode` (`c pos size`) [S1] and recorded in the mapfile. Then
  TestDisk, TSK or a mount pull only what they need.
- This is the idea of OSC's Virtual Disk Mode [S5] without its kernel driver.
- `nbdkit` is in `extra`. Whether its plugin API fits a blocking ddrescue
  backend is **not verified**.
- Risk high (filesystem tools issue many small reads, so wear and latency).
  Research only.

### O18 — Image only the allocated blocks first (P2)

Build a domain mapfile of used blocks and pass it with `-m`:

- partclone's domain output, as the ddrescue manual mentions [S1];
- or `ddrescuelog -c` from a block list of TSK `blkls`/`fiwalk`.

The important data then comes out before the free space. This is what
"filesystem-map imaging" does in UFS Explorer [S38]. Needs care: the metadata
must be read first, from the failing drive.

### O19 — Live-USB awareness (P2)

`--doctor` notes when the failing drive is the running system and suggests a
live system (SystemRescue ships the same tools [S22]).

## 8. Prioritized opportunity matrix

Complexity, risk and UX are rated H(igh)/M(edium)/L(ow). "Deps" are the
packages in the configured repos unless noted.

| ID | Opportunity | P | Complexity | Tech. risk | UX impact | Deps / license viability |
| --- | --- | --- | --- | --- | --- | --- |
| O1 | Files touching unread areas of an image, from the mapfile (`fiwalk`/`ifind`, `ntfscluster`, `filefrag`) | **P0** | M | L | H | sleuthkit (subprocess; CPL/IPL parts: do not link), ntfsprogs, e2fsprogs |
| O2 | SHA-256 manifests of copies, images and exports; "check this rescue" | **P0** | L | L | M | coreutils |
| O3 | Per-file ddrescue for large or partially readable files: block resume, partial kept, *Partial* result word | **P0** | M | M | H | ddrescue (already optdep; GPL-2.0+) |
| O4 | Stop conditions (`--timeout`, `--max-error-rate`, `-X`), `ddrescue >= 1.30` check, dead-head hint (`--no-sweep`) | P1 | L | L | M | ddrescue 1.30 |
| O5 | Damage map from the mapfile (window, terminal, report) | P1 | L–M | none | H | none |
| O6 | Open an image read-only (loop `-r`), first-class | P1 | L | L | M | udisks2, util-linux |
| O7 | Browse and recover deleted files on images with TSK, gated by the §4 matrix | P1 | M | L | H | sleuthkit (subprocess) |
| O8/O9 | Structural validation of carved candidates (*Opens / Damaged / Unknown*) | P1 | M | M (untrusted parsers) | H | testdisk (`fidentify`), python-pillow, qpdf, 7zip/unzip, ffmpeg, flac (all optional) |
| O10 | `smartctl -j` in the helper | P1 | L | L | L–M | smartmontools 7.5 |
| O12a | LVM (single PV) from an image, read-only | P1 | M | M (duplicate UUIDs, activation semantics) | M | lvm2 |
| O13 | XFS `norecovery` / Btrfs `rescue=` mounts and `btrfs restore` on image loops | P1 | M | M (new helper verb) | M | xfsprogs, btrfs-progs |
| O12b | md RAID virtual assembly from member images (readonly, overlays) | P2 | H | H | M | mdadm, device-mapper |
| O14 | ZFS pool import from images, read-only, no rewind | P2 | M | M | L | zfs-utils (CDDL: subprocess only) |
| O15 | E01 input (TSK/PhotoRec/`ewfmount`) and output (`ewfacquire` from a raw image) | P2 | L–M | L | L | libewf (LGPL-3.0+; repo has the 2014 legacy line) |
| O16 | Dissect as an optional external reader | P2 | M | M | L | AGPL-3.0, not packaged: not recommended |
| O17 | On-demand imaging through NBD plus `ddrescue --command-mode` | P2 | H | H | M | nbdkit, ddrescue |
| O18 | Domain mapfile: image allocated blocks first | P2 | M | M | M | partclone / sleuthkit, ddrescuelog |
| O19 | Live-USB awareness in `--doctor` | P2 | L | L | L | none |

**Non-goals** (consistent with docs 08 and 12):

- Direct AHCI/IDE/USB access, relay power cycling and kernel drivers
  (OpenSuperClone [S6][S8]).
- Firmware or service-area work (PC-3000 [S41]).
- Any repair: `fsck`, TestDisk write, `zpool import -F/-X`, `mdadm --create` on
  real members.
- ext4magic [S24].
- Long SMART self-tests.

## 9. Sources

- [S1] GNU ddrescue Manual 1.30 — https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html
- [S2] GNU ddrescue 1.30 announcement (2026-01-04) — https://lists.gnu.org/archive/html/bug-ddrescue/2026-01/msg00000.html
- [S3] `ddrescuelog(1)`, ddrescue 1.30 (local man page, package `ddrescue 1.30-2`)
- [S4] OpenSuperClone repository — https://github.com/ISpillMyDrink/OpenSuperClone (release and activity dates from the GitHub API, 2026-11-02)
- [S5] OpenSuperClone wiki, Virtual Disk Mode — https://github.com/ISpillMyDrink/OpenSuperClone/wiki/Virtual-Disk-Mode
- [S6] OpenSuperClone wiki, Direct Modes — https://github.com/ISpillMyDrink/OpenSuperClone/wiki/Direct-Modes
- [S7] OpenSuperClone wiki, Recovery Phases — https://github.com/ISpillMyDrink/OpenSuperClone/wiki/Recovery-Phases
- [S8] OpenSuperClone wiki, Relay Operation — https://github.com/ISpillMyDrink/OpenSuperClone/wiki/Relay-Operation
- [S9] HDDSuperClone skipping, user forum (not official) — https://www.technibble.com/forums/threads/error-cloning-drive-with-hddsuperclone.87468
- [S10] ddrescueview — https://sourceforge.net/projects/ddrescueview/
- [S11] TestDisk — https://www.cgsecurity.org/wiki/TestDisk
- [S12] PhotoRec — https://www.cgsecurity.org/wiki/PhotoRec
- [S13] The Sleuth Kit, description — https://www.sleuthkit.org/sleuthkit/desc.php
- [S14] The Sleuth Kit NEWS — https://github.com/sleuthkit/sleuthkit/blob/develop/NEWS.txt ; 4.15.0 release — https://github.com/sleuthkit/sleuthkit/releases/tag/sleuthkit-4.15.0
- [S15] `fls` — https://www.sleuthkit.org/sleuthkit/man/fls.html
- [S16] `icat` — https://www.sleuthkit.org/sleuthkit/man/icat.html
- [S17] `tsk_recover` — https://www.sleuthkit.org/sleuthkit/man/tsk_recover.html
- [S18] The Sleuth Kit licenses — https://github.com/sleuthkit/sleuthkit/tree/develop/licenses
- [S19] Autopsy — https://github.com/sleuthkit/autopsy
- [S20] Rescuezilla — https://github.com/rescuezilla/rescuezilla
- [S21] Clonezilla `ocs-sr` — https://clonezilla.org/fine-print-live-doc.php?path=clonezilla-live/doc/98_ocs_related_command_manpages/01-ocs-sr.doc
- [S22] SystemRescue — https://www.system-rescue.org/ ; changes — https://www.system-rescue.org/Changes-x86/
- [S23] extundelete — https://extundelete.sourceforge.net/
- [S24] ext4magic — https://sourceforge.net/projects/ext4magic/
- [S25] DFRWS 2012, "An analysis of Ext4 for digital forensics" — https://dfrws.org/sites/default/files/session-files/2012_USA_pres-an_analysis_of_ext4_for_digital_forensics.pdf
- [S26] xfs_undelete — https://github.com/ianka/xfs_undelete
- [S27] `btrfs-restore(8)` — https://btrfs.readthedocs.io/en/latest/btrfs-restore.html
- [S28] Foremost — https://foremost.sourceforge.net/
- [S29] Scalpel — https://github.com/sleuthkit/scalpel
- [S30] `zpool-import(8)` — https://openzfs.github.io/openzfs-docs/man/master/8/zpool-import.8.html
- [S31] `zpoolprops(7)` — https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html
- [S32] `zdb(8)` — https://openzfs.github.io/openzfs-docs/man/master/8/zdb.8.html
- [S33] `smartctl(8)` 7.5 (local man page; smartmontools.org blocked the fetch)
- [S34] nvme-cli — https://github.com/linux-nvme/nvme-cli ; `nvme-smart-log(1)` 3.1 (local)
- [S35] libewf — https://github.com/libyal/libewf ; libewf-legacy — https://github.com/libyal/libewf-legacy
- [S36] Dissect — https://github.com/fox-it/dissect ; https://github.com/fox-it/dissect.volume ; https://github.com/fox-it/dissect.fve ; https://github.com/fox-it/dissect.evidence
- [S37] R-Studio for Linux (vendor) — https://www.r-studio.com/data_recovery_linux/
- [S38] UFS Explorer Professional Recovery (vendor) — https://www.ufsexplorer.com/ufs-explorer-professional-recovery/
- [S39] DMDE (vendor) — https://dmde.com/
- [S40] Disk Drill byte-to-byte backup (vendor) — https://www.cleverfiles.com/help/dmg-iso-backup.html
- [S41] PC-3000 Express (vendor) — https://www.acelab.eu.com/pc3000.express.php
- [S42] Linux RAID wiki, overlay files — https://archive.kernel.org/oldwiki/raid.wiki.kernel.org/index.php/Irreversible_mdadm_failure_recovery.html
- [S43] Local man pages: `mdadm(8)` (`--readonly`), `vgchange(8)` (`--readonly`), `lvchange(8)` (`-p r`), `losetup(8)` (`-r`), `ntfsundelete(8)`, `ntfscluster(8)`, `filefrag(8)`
- [S44] FSF, licenses and GPL compatibility — https://www.gnu.org/licenses/license-list.html
- [S45] libyal filesystem libraries (LGPL-3.0) — https://github.com/libyal/libfsapfs , https://github.com/libyal/libfsxfs , https://github.com/libyal/libfshfs

### Carving tools not detailed above

- **Foremost** 1.5.7. Built at the US Air Force OSI. Carves by header, footer
  and internal structures. Works on dd/EnCase images or drives [S28]. Repo:
  `foremost 1.5.7-7` (license "custom").
- **Scalpel.** Apache-2.0 since 2013, based on Foremost 0.69. "It is not being
  actively maintained", no official releases, last commit 2021 [S29]. Not in the
  configured repos.

PhotoRec, already integrated, covers more formats [S12]. Neither Foremost nor
Scalpel is recommended as a second carver: no comparative test was run, and
they would duplicate the results browser.
