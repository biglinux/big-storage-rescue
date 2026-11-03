# 21 — What was done, how it was validated, what is left (2026-11-03)

Follows the audit (00) and the benchmark (20). These are local commits on
`feature/world-class-recovery`, after `146bde8`. Nothing was pushed. The
package was not installed again, because a rescue was running on the
development machine.

## Phases

| Phase | Done |
| --- | --- |
| 0 Inventory | doc 00; all suites green at the start |
| 1 Research | doc 20 (25 tools, capability matrix, priorities, 45 sources) |
| 2 Security | commit "Harden the privileged helper…" (below) |
| 3 Recovery engine | salvage, map, integrity check, manifests |
| 4–6 Experience | map on the image page, salvage offered on a copy, verdicts on the results page, new screenshots |
| 7 Professional | SHA-256 manifests (the base of a forensic mode); the rest is on the roadmap |
| 8 Optimisation | the costs below; nothing in the list or the start-up path changed |
| 9 Quality | ShellCheck, ruff, all suites, i18n complete |
| 10 Delivery | README, docs 08/09/11/12/15, this file |

## Security (commit `3b278d5`)

- **`image` refuses the running system.** The helper's `image` verb refuses
  the drives of the running system. It refuses a loop device unless the file
  behind it belongs to the user. Both checks run again once the files are open.
- **Own polkit action for `image`.** `image` has its own polkit action,
  `org.biglinux.big-storage-rescue.image`, selected by
  `org.freedesktop.policykit.exec.argv1`. It is `auth_admin` with no `_keep`,
  and it comes first in the file. The generic action keeps `auth_admin_keep`
  for protect, smart and partitions. **Not validated with a real polkit
  agent:** pkexec's documented behaviour was relied on (`man pkexec`; this
  pkexec has the annotation).
- **User files opened safely.** A small `python3 -I` step
  (`BSR_OPEN_OWN` in the helper) opens the user's files:
  - it walks every folder from `/` with `O_PATH|O_NOFOLLOW`;
  - it opens the leaf as a path only, so a device or FIFO is never really opened;
  - it requires a regular file with one name that belongs to the user, or creates it with `O_EXCL`;
  - it reopens the file through `/proc/self/fd`, removes on refusal what it created, and runs the helper again with the descriptors open.

  Root no longer opens a user path by name.

  The inner verb that this step runs, `__image-opened`, needs the mark the step
  puts in its environment (`BSR_IMAGE_OPENED=1`). pkexec passes only a fixed list
  of variables, so `pkexec bsr-drive-helper __image-opened …`, through the
  action of the other verbs, which keeps the password a while, is refused.
  Found by the review of the pull request.
- **Map checks.** A map is refused above 64 MiB, or if any line is not map grammar.
- **Disk sequence number.** protect, unprotect and image take it and check it right before acting. Exit code 5 means "replaced".
- **Map saved more often.** ddrescue now saves the map every 5 s, for images.
- **Smaller fixes.**
  - Numbers from `state.env` are kept only if they are digits.
  - Thumbnails above 100 megapixels are refused.
  - The GObject types were renamed.

Not done, with the reason:
- **Destination over FUSE/overlay or a loop backed on the source.** The review
  pointed out that "never onto the disk being read" cannot be checked when the
  destination is on FUSE, overlay or a loop over a file of the source. Refusing
  destinations that are not block devices would also refuse network shares,
  which are legitimate. It is documented as a user-error case.
- **Decoding thumbnails in a subprocess.** The pixel limit covers decompression
  bombs. Running gdk-pixbuf in a subprocess with an rlimit is on the roadmap.

## Salvage (commit `77dd913`, GUI `832cb5d`)

### Problem

A copy loses a file whole at the first read error. A large file that was
interrupted starts over.

### Options weighed

| Option | Why not |
| --- | --- |
| `rsync --append` / `--append-verify` | Forbidden by the brief. `--append` trusts whatever partial file is there. `--append-verify` reads the whole source file again to verify, which is extra wear on a failing disk. |
| `rsync --partial-dir` | Local copies use `--whole-file`, so the partial file is not used as a delta base. Without `--whole-file`, the delta algorithm reads the whole source file again. |
| Routing large files through ddrescue in the main pass | Possible later. It would change the main copy, whose guarantee is "a file with its final name is complete". It needs its own review. |
| **GNU ddrescue per file, after the copy, as a job of its own** | Chosen: <ul><li>no new privilege (a regular file is read as the user);</li><li>a map per file gives block-level resume;</li><li>unreadable areas are known by byte range;</li><li>the main copy is unchanged.</li></ul> |

### Decision

`--cli salvage COPY_ID` takes the files the copy left out:
- the ones in `failed.txt` and `deferred.txt`;
- only regular files that are not empty and are still in the source, checked with a `stat` that has a time limit;
- never a name outside the source.

Then it starts a `salvage` job:
- ddrescue runs with `-q --extend-outfile=SIZE --mapfile-interval=1 --no-scrape`, or `--retry-passes=N` when the person asks;
- it works under ionice and nice;
- the output goes to a work folder at the destination, the map to the job folder.

Where each file goes:
- **Read completely:** to its place, with no overwrite and no escape through a linked folder.
- **With holes:** to `Partly recovered files - DATE/<path>`, plus `unreadable areas.txt` listing the byte ranges.

Every file gets its source date.

What the job protects against:
- **Source file changed:** a map is not continued on new content.
- **Map without its file:** both start over, because ddrescue would skip areas whose data is gone.
- **Pause, cancel, unmount:** each stops ddrescue with SIGTERM, which saves the map.

The window offers "Save what can be read…" on a copy that left files out. It shows the dry run first and starts only after consent.

## Map of an image (`77dd913`, GUI `832cb5d`)

`--cli map ID [--bins N] [--json]` reduces the map of a disk to N cells in
one awk pass. Each cell gets its worst status and how much of it was read,
in tenths.

The image page draws the cells with cairo: one rectangle per cell, never a
widget per sector. It refreshes every 6 s while the image runs, and once
when it stops.

Colour is never the only sign:
- a cross marks an unreadable cell;
- a dot marks a cell to retry;
- a cell read in part is filled in part;
- a summary says the same in words, also to a screen reader (`AccessibleRole.IMG` with a label).

In a narrow window the grid takes fewer columns, so a cell is never too small for its mark.

In the terminal it is a 64-column grid.

## Integrity of what a search found (`d66ae05`)

`integrity.py` looks at structure only:
- JPEG markers and end;
- PNG chunks with CRC, computed in 1 MiB pieces, IHDR first and image data before the end;
- GIF and PDF end markers;
- the central directory of a zip (docx, xlsx, odt, epub, …), and for a zip64 the record that describes it;
- the chain of boxes of an MP4 or MOV, which must reach the end and contain `moov`;
- the declared size of RIFF (WAV, AVI, WebP), BMP and SQLite.

Each file gets one verdict:
- *complete*;
- *truncated*;
- *damaged*;
- *unknown*, for formats it does not check, links (never followed) and paths outside the root (never opened).

There is one answer per record of the index, in order.

It runs at the end of a search, as a "verifying" phase that can be
cancelled and reads only the destination. `--cli check-files ID` runs it
again. The results page shows the counts, with the sentence "Whole does not
prove every byte is right", and marks *Cut short* or *Damaged* next to the
name.

## Manifests (`c55194d`)

`--cli manifest ID [--output FILE]` writes the SHA-256 of what was written:
- for a copy, every file in the rsync log, once;
- for a salvage, where each file was placed;
- for an image, the image file, with the source disk, its serial and size, and a note that unreadable areas are zeros.

The format is sha256sum's, with a header, so `sha256sum -c` checks it in
the destination folder. Only the destination is read.

## Validation, feature by feature

U: unit test (engine functions, fixtures). I: integration with real tools on
scratch files (real GNU ddrescue, real rsync, real Python). G: graphical test
(Broadway). L: laboratory test on a real failing or emulated device. H:
validated on real hardware.

| Feature | U | I | G | L | H |
| --- | --- | --- | --- | --- | --- |
| Salvage: holes, placement, dates, sidecar, refusals | ✓ | ✓ ddrescue `--test-mode` | ✓ | — | — |
| Salvage: pause then resume without re-reading (the second run is told the first-read area is now bad; the file still comes out whole) | | ✓ | | — | — |
| Map: totals, cells, grid; 40 001 areas on 4 TB | ✓ | ✓ | ✓ | — | — |
| Integrity: 16 synthetic files of 7 formats, link, traversal | ✓ | ✓ | ✓ | — | — |
| Manifests: copy, image, salvage; `sha256sum -c`; a change is caught | ✓ | ✓ | | — | — |
| Helper opener: links on the way, link leaf, FIFO, hard link, foreign folder, `..`, cleanup | | ✓ (as the user) | | — | — |
| Helper `image` refusing the system; diskseq; polkit argv1 action | static checks + engine fakes | — | | — | — |
| statfs limit with a really hung mount | | ✓ (/var/tmp stand-in) | | ✓ (a real stuck FUSE mount on the dev machine: `--doctor` 0.9 s) | — |

None of this was run as root: the helper's root path, and a real polkit
prompt, are **not validated**. No real failing drive was used by the tests
(rules of the brief). dm-error/dm-delay laboratories need root and loop
devices: `tests/drive-integration.sh` is the place for them. They were not
added in this work.

## Results

| Suite | Before (`146bde8`) | After |
| --- | --- | --- |
| lib-tests | 267 | 267 (the stuck-statfs check is real again) |
| drive-tests | 312 | **380** |
| migrate-tests | 41 | 41 |
| i18n-tests | 37 | 37 (pt_BR complete: 0 untranslated, 0 fuzzy) |
| package-check | 102 | **107** |
| gui-tests | 165 | **173** |
| gui-e2e | 7 | 7 |
| ShellCheck (CI set), `bash -n`, ruff | clean | clean |

## Costs measured

On the development machine (warm cache):

| What | Cost |
| --- | --- |
| `integrity.py` on 5 000 carved files (1.2 GB, every PNG CRC computed) | 0.41 s |
| `--cli map` on a map of 40 001 areas for 4 TB, 1 024 cells | 0.16 s |
| The image page | one `map` question every 6 s while running |

With a cold cache the integrity check is bound by the destination disk: it
reads the first and last 64 KiB of most files, and all of a PNG.

No change touched the drive list, the start-up or the window's idle state.

## Not resolved

- XFS/Btrfs that need log replay (path: read-only loop of an image).
- The main copy still restarts an interrupted large file. Salvage covers it
  afterwards, block by block.
- A salvage onto FAT32 fails for files of 4 GiB or more.
- Unread areas of an image are not yet mapped to the files they hit.
- The manifest and check-files are terminal commands. The window does not
  offer them yet, except the automatic check at the end of a search.

## Needs real hardware

- LVM, RAID, multi-device Btrfs, SD, eMMC.
- A real polkit prompt for the new image action.
- The helper as root with a real failing disk.
- A screen reader session.
- A GNOME session.

## Roadmap

1. **P0** — Map the unread ranges of an image to files (Sleuth Kit `fiwalk`/`ifind`, `ntfscluster`, `filefrag`), so a file restored from an image with zero-filled holes is never shown as whole.
2. **P1** — ddrescue stop conditions for images (`--timeout`, `--max-read-errors`), the same idea as "more than 100 files set aside stops a copy".
3. **P1** — Open an image read-only inside the app (`udisksctl loop-setup -r`). Then:
   - Sleuth Kit browsing of deleted files, only where it works (ext2, NTFS, FAT, exFAT; names only on ext3/4);
   - XFS `norecovery` and Btrfs `rescue=` mounts on the loop.
4. **P1** — `smartctl -j` in the helper, instead of parsing text.
5. **P1** — The window: manifest and check-files buttons; a salvage map per file.
6. **P2** — LVM and md from images, read-only.
7. **P2** — A forensic case mode built on the manifests: case folder, timeline of jobs, tools and versions used.
8. **P2** — E01 through libewf.
9. **P2** — Thumbnails decoded in a subprocess with limits.
