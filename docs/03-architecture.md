# 03 — Architecture

```
/usr/bin/big-storage-rescue            entry point: finds its library, calls bsr_main
/usr/lib/big-storage-rescue/
  cli.sh        dispatcher, diagnosis, busy, safe removal, notifier, quick dialogs
  lib.sh        device facts, read-only causes, holders, UDisks2, drive health
  ui.sh         one document model rendered as a GTK dialog or terminal text
  doctor.sh     --version, --doctor           (loaded only by them)
  migrate.sh    state of Big-Mount 2.x        (loaded only when there is some)
  drive.sh      --cli: commands, JSON, helper (loaded only by --cli and --gui)
  drive-detect.sh  drive-diag.sh  drive-copy.sh  drive-recovery.sh  drive-tui.sh
  app.py  gui/  the application (GTK 4, libadwaita, Python)
  dialog.py     the quick dialogs of --gui-diagnose, --gui-remove and the notifier
  bsr-holders        pkexec: lsof of every user for one mount point (read-only)
  bsr-drive-helper   pkexec: protect/unprotect, smart, partitions, image
  bsr-image-helper   pkexec: a disk image (its own polkit action), runs bsr-drive-helper image
```

## One engine

```
 Dolphin / menu / notifier            terminal, SSH, scripts
          │                                   │
   app.py (GTK 4)  ── Gio.Subprocess ──►  big-storage-rescue --cli COMMAND [--json]
                                              │
                         drive.sh · drive-*.sh · lib.sh   (bash, as the user)
                                              │
              UDisks2 (D-Bus) · udev · /proc · /sys · rsync · pkexec helpers
```

The window decides nothing about disks: `gui/engine.py` runs
`big-storage-rescue --cli … --json` and shows the answer. Critical logic
(what is safe, what was copied, what a state means) exists once, in shell.
A question has a 60 s limit; an operation (mount, unmount, the start of a job)
always runs to its end, and the window waits for it before closing.

## Jobs

A copy, an image, a list of files or a search is a job: a folder in
`~/.local/state/big-storage-rescue/jobs/ID` and a supervisor
(`big-storage-rescue --cli __run ID`, started with `setsid -f`) that does not
depend on the window or the terminal. The supervisor holds `ID/lock`; a job
whose supervisor is gone is shown as *interrupted* and can be resumed.

## Relation with Big-Mount

None is required. Big Storage Rescue reads, when present:

- `/run/big-mount/status` — what the boot run mounted, and why a partition was
  mounted read-only (`bsr_boot_status`, `--diagnose`, `--doctor`);
- `systemctl is-enabled big-mount.service`, `/etc/bigmountall-no`,
  `/etc/big-mount.conf` — shown in `--diagnose` and `--doctor` only.

It never writes them, never restarts the service and never unmounts the
partitions of the running system. Everything else comes from the kernel,
udev and UDisks2, so the same works on a system without Big-Mount.

## What runs at boot

Nothing. The package has no systemd unit, no pacman hook and nothing in
`/etc`. The notifier runs in the session only when the person turns it on.
