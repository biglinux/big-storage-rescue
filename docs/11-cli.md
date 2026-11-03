# 11 — Command line

```
big-storage-rescue                      the application (graphical session) or the manager (terminal)
big-storage-rescue --gui [TARGET]       the application
big-storage-rescue --gui-health [TARGET]
big-storage-rescue --gui-rescue [TARGET]
big-storage-rescue --cli [COMMAND]      the drive manager: menus without COMMAND, also over SSH
big-storage-rescue --diagnose [TARGET]  overview, or why one device cannot be written to
big-storage-rescue --busy TARGET
big-storage-rescue --unmount TARGET
big-storage-rescue --safe-remove TARGET [--no-power-off] [--close-apps] [--assume-yes]
big-storage-rescue --gui-diagnose [TARGET] | --gui-remove TARGET     (Dolphin)
big-storage-rescue --notifier
big-storage-rescue --migrate-state [--dry-run]
big-storage-rescue --doctor | --version | --help
```

`TARGET` is a device (`/dev/sdb1`), a folder inside a mounted device, or (for
`--gui*` and `--cli`) a filesystem UUID.

## `--cli` commands

`list`, `inspect`, `resolve`, `diagnose [--smart]`, `mount [--read-only|--protect|--remount|--read-write]`,
`unmount`, `safe-remove`, `busy`, `close-apps`, `protect`, `unprotect`, `unlock`,
`destinations`, `copy`, `jobs`, `status [--watch]`, `pause`, `cancel`, `resume [--retry-deferred]`,
`report [--anonymize] [--output FILE [--replace]]`, `methods`, `image`, `partitions [--search]`,
`scan`, `carve`, `results`, `check-files`, `salvage [--retries N]`, `map [--bins N]`,
`manifest [--output FILE]`. `big-storage-rescue --cli --help` describes each.

- `--json` on every command: one JSON object on standard output. This is what
  the application uses, so it is complete and stable. Device data and file
  names are escaped (`bsr_js`); control characters never reach a terminal.
- `--dry-run` on the commands that change something: says what would be done.
- `--drive` is accepted as a synonym of `--cli`, as in Big-Mount 2.x.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | done |
| 1 | error |
| 2 | usage |
| 3 | device busy (or: a job of Big-Mount is still running, for `--migrate-state`) |
| 4 | refused: it holds the running system |
| 5 | not authorized, or cancelled |
| 6 | unmounted, but still in use by a stacked device |
| 7 | unmounted; this drive cannot be powered off by the computer |
| 8 | unmounted, but powering it off failed |
| 9 | not done: services depend on it and were not confirmed |
| 10 | another operation on the same drive or job is in progress |
| 20 | refused by a safety check |
| 21 | not enough space |
| 22 | finished, but some files were not copied, or the check found differences |
| 23 | cancelled or paused |
| 24 | a device went away or did not answer |
| 25 | a tool is missing (ddrescue, testdisk, smartctl, rsync, GTK) |

## Terminals

Colours only on a terminal, never with `NO_COLOR` or `TERM=dumb`; box
characters only with a UTF-8 locale; input line by line, so it works over SSH
and in a serial console. The graphical commands refuse to run as root and say
which terminal command does the same. Without a polkit agent (SSH), the
helper-based operations need `sudo big-storage-rescue --cli …` or fail with 5.

## Examples

```bash
big-storage-rescue --diagnose ~/Pendrive              # why can't I write here?
big-storage-rescue --cli list --json | jq '.devices[] | {name, kind, health}'
big-storage-rescue --cli copy --source /run/media/me/OLD --destination /mnt/backup/rescue --no-wait
big-storage-rescue --cli status 20261102-101500-ab12 --watch
big-storage-rescue --cli image --source /dev/sdc --image /mnt/backup/sdc.img
big-storage-rescue --cli carve --source /mnt/backup/sdc.img --destination /mnt/backup/found --categories photos,documents
big-storage-rescue --cli report /dev/sdc --anonymize --output sdc.txt
```
