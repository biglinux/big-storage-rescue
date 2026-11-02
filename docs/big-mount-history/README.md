# Big-Mount history (2.0 – 2.6)

These documents were written while the drive manager, the diagnosis and the
file rescue were still part of Big-Mount (`bigmount --drive`, `--gui-drive`,
`/usr/lib/big-mount`). They are kept unchanged as the record of why the code
is the way it is: the field report of a real failing disk (12), the copy
engine (16), the security review (17) and the GTK unification
(`gtk-unification/`).

Names in them are the old ones. In Big Storage Rescue:

| Big-Mount 2.x | Big Storage Rescue |
| --- | --- |
| `bigmount --drive …` | `big-storage-rescue --cli …` |
| `bigmount --gui-drive` / `--gui-drive-check` | `big-storage-rescue --gui` / `--gui-health` |
| `bigmount --gui DEV` (dialog) | `big-storage-rescue --gui-diagnose DEV` |
| `/usr/lib/big-mount/` | `/usr/lib/big-storage-rescue/` |
| `bigmount-drive-helper`, `bigmount-holders` | `bsr-drive-helper`, `bsr-holders` |
| `bm_*` functions, `BM_*` variables | `bsr_*`, `BSR_*` |
| `~/.local/state/big-mount/jobs` | `~/.local/state/big-storage-rescue/jobs` |
| Secure Erase (14) | not part of Big Storage Rescue (see ../12-security.md) |

The automount itself (documents 02, 03 and the boot parts of 08) stays in
Big-Mount.
