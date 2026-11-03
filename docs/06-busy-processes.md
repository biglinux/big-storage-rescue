# 06 — What keeps a device busy

`bsr_busy_collect` (`cli.sh`) gathers, for every mount of the device:

- **processes** (`bsr_holders`, `lsof -F` on the mount point): PID, program,
  application name from its `.desktop` entry, owner, start time, state, file
  descriptor (`cwd`, `rtd`, `txt`, `mem` or a number), access (read, write,
  read/write) and the path;
- **everything else** (`bsr_other_holders`): another mount of it, a device
  mounted inside it, a swap file or swap partition, a loop device whose image
  lives on it, a LUKS/LVM/RAID holder, and mounts in other mount namespaces
  (containers, sandboxed services), which keep it busy invisibly;
- **services** that systemd stops with the mount (`BindsTo=`, `Requires=`):
  `bsr_mount_dependents`.

`bsr_busy_summary` then says in one sentence what matters most to a person:
something writing, a terminal in a folder of it, a file manager, the indexer,
another program.

An ordinary user cannot see the processes of other users. The question is
then answered honestly ("none of *your* programs"), and *Show programs of all
users* runs `bsr-holders` through pkexec
(`org.biglinux.big-storage-rescue.inspect-processes`, administrator password,
read-only, one mount point of a local block device, never the running system).

## Closing programs

Only on request (`--close-apps`, *Close the listed programs…*), and never:

- the session and the system (`BSR_PROTECTED_COMM`: Plasma, KWin, Xwayland,
  D-Bus, PipeWire, polkit, UDisks2, `bigmount`, this program…);
- a process of another user or of root;
- a process that has a file open for **writing** (it would lose data);
- an interactive shell (it ignores SIGTERM: the person is asked to `cd` away).

Each process is identified by PID **and** start time, so a PID reused by
another program is not signalled. Programs get SIGTERM, as when their window
is closed; nothing is killed with SIGKILL.

Commands: `big-storage-rescue --busy TARGET`, `--cli busy TARGET [--json]`,
`--cli close-apps TARGET`. Exit code 3 means busy.
