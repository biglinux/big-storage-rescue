# 02 — Migration plan, as carried out

1. **History first.** The new repository starts from the history of Big-Mount
   (`git fetch ../big-mount feature/biglinux-2.6.0`), on the branch
   `feature/migrate-from-big-mount`. Every line keeps its author and the commit
   that explains it; `git log --follow` works across the renames.
2. **Move, then change.** One commit only moves files into the new layout
   (`git mv`), so rename detection stays exact. Removed in that commit: the boot
   automount and its tests, and Secure Erase.
3. **Rename the identifiers** with a script that protects the integration points
   with Big-Mount (`/run/big-mount/status`, `big-mount.service`,
   `/etc/big-mount.conf`, `/etc/bigmountall-no`), then review every remaining
   occurrence by hand. The same renaming was applied to `pt_BR.po`, so the
   existing translations keep matching their messages.
4. **New entry point** `/usr/bin/big-storage-rescue` and a new dispatcher in `cli.sh`.
5. **Persistent state**: `migrate.sh` (see 16-migration-validation.md).
6. **Tests** adapted, never deleted because they failed: the Secure Erase cases
   went with Secure Erase, the boot cases went to Big-Mount.
7. **Only then** Big-Mount is simplified, on its own branch
   (`feature/automount-only`), keeping the boot path unchanged.

## Command mapping

| Big-Mount 2.x | Big Storage Rescue |
| --- | --- |
| `bigmount --gui-drive [T]` | `big-storage-rescue --gui [T]` (also: no option, in a graphical session) |
| `bigmount --gui-drive-check [T]` | `big-storage-rescue --gui-health [T]` |
| — | `big-storage-rescue --gui-rescue [T]` (new: opens the recovery assistant) |
| `bigmount --drive [CMD]` | `big-storage-rescue --cli [CMD]` (`--drive` still accepted) |
| `bigmount --gui DEV` | `big-storage-rescue --gui-diagnose DEV` |
| `bigmount --gui-remove`, `--diagnose`, `--busy`, `--unmount`, `--safe-remove`, `--notifier`, `--doctor`, `--version` | same option names |
| `bigmount --secure-erase`, `--drive erase-check` | removed |
| — | `big-storage-rescue --migrate-state [--dry-run]` |

In Big-Mount the old options print the new command and exit 2, without loading
anything (see the Big-Mount repository, `docs/02-split.md`).
