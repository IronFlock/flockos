# ADR-0015: A factory reset, requested on the IRONFLOCKOS partition, makes a new /data at the next boot, and never keeps a device offline

Status: accepted, 2026-11-10. Failure handling replaced on 2026-11-11 (section 2).

## Context

IronFlockOS had no factory reset. A device that is enrolled again keeps what the old
identity left: the agent's folder, Docker's images and containers, the homes, the logs,
the SSH host keys. The only clean way back was a reflash, which needs the boot medium in
another computer, or the installer stick.

The `ironflock` command of device-init gets `ironflock os reset [-c new.flock]
[--keep-network]` (its plan, WP-5.5): it lists what is lost, asks, requests the reset and
restarts. The device does the reset itself, at its next boot, before anything uses the
data partition. A device on WiFi or behind a proxy that loses its network settings never
comes back online, so they can be kept on request.

What the old owner leaves is not on `/data` alone. `ironflock-init enroll` writes into the
root slot it runs in: the SSH user of the `.flock` (with a NOPASSWD sudo rule), the agent's
unit, the hostname, and `/var/lib/ironflockos/enrolled`. The device-agent runs apps with
`-appsDir /apps`, which on this branch is in the root slot too. After an A/B update the
other slot still holds the system the device ran before, with the same leftovers.

Every target has to be served: amd64-efi and arm64-efi with GRUB, the Raspberry Pi with
the firmware's tryboot, Jetson with NVIDIA's boot chain, the Compute Engine images. Only
the EFI targets have EFI variables; every target has the FAT partition the `.flock` comes
on (`IRONFLOCKOS`; on Jetson NVIDIA's ESP), mounted at `/boot/efi`.

The device-agent's connection is the only way to a device in the field (the lifeline rule
of the device-agent, `.github/copilot-instructions.md` there). The root account is
locked, so the emergency mode systemd falls back to when a mount fails offers nobody a
shell.

## Decision

### 1. The owner's decision

On 2026-11-11 the owner decided how a failing reset ends:

> it is most important that a device always comes online after a time to always ensure
> remote servicability. Like the lifeline doctrine in device-agent. So ... the
> alternative is the better solution: give up after a few attempts and boot what is
> there.

It replaces the first design, in which a reset that had begun stopped the boot until it
completed, and repeated while the IRONFLOCKOS partition could not remove its files.
Everything below beyond these words is this ADR's design: the number of attempts, where
the count lives, the time limits, and what a device does without `/data`.

### 2. A reset never keeps a device offline

- **Three attempts per request.** An attempt is counted before it starts. A failed
  attempt is recorded, and the boot goes on to multi-user with what `/data` holds; the
  next boot tries again. After the third failure the reset gives up: the request no
  longer triggers it, and the device boots with the old `/data`, or, when the reset had
  begun to erase it, a new one. Three, because one retry covers a power loss or a
  transient error, a second covers a power loss during the retry, and more attempts
  only lengthen the time a device with a failing disk spends in a reset.
- **The count** lives in the booted root slot, `/var/lib/ironflockos/factory-reset.state`,
  with the request it belongs to: the slot survives a read-only or missing IRONFLOCKOS
  partition, a `/data` that cannot be mounted, and a power loss (the file is written
  under another name, synced and renamed). A request is told from another one by its
  checksum, size and time of change. Only a request written anew is a new one.
- **A request that ended never fires again**, held by three marks, each enough alone:
  the request is renamed to `factory-reset.conf.gave-up` when the reset gives up (a
  completed one is removed); the outcome is marked on `/data`
  (`ironflockos/factory-reset.done`, `outcome=done` or `outcome=gave-up`), which every slot
  reads; and the state goes with each update into the new slot (`rauc-post-install`,
  never a reason for the update to fail). A slot without the state, after a rollback or
  an update, finds the mark on `/data`; with the request renamed nothing runs at all.
  What remains: a request that gave up while the IRONFLOCKOS partition was read-only and
  `/data` could not be written either, found by a slot without the state (a rollback).
  Such a device can count attempts again, but while its IRONFLOCKOS partition stays
  read-only no attempt can begin, as the kept files go there first; once it is
  writable, the slot that gave up renames the request at its next boot.
- **No count, no attempt.** Where the count cannot be written, there is no attempt: the
  device boots as it is, the old identity runs on, and the console and the record say
  why. A device where nothing can be written at all therefore never resets, and always
  comes up.
- **One restart, once.** The reset restarts the device only after it has completed, to
  boot with a new machine-id. A completed reset is marked done in the state and on the
  new `/data` (`ironflockos/factory-reset.done`, which either slot reads), before its request
  is removed: a request that cannot be removed, or comes back unchanged, or is found by
  the other slot, is not done a second time. If even the restart cannot be asked for, a
  new machine-id is written and the boot goes on.
- **Time limits.** A whole attempt has 25 minutes, `mkfs.ext4` 15 of them, a mount or an
  unmount 2, copying the kept files 5, clearing a slot 10, `grub-editenv`, `sync`,
  `lsblk` and `blkid` 1. Running into a limit is a failed attempt. The unit's own limit,
  60 minutes, is the last net for a disk that blocks even the commands that kill.
- **Nothing requires the reset.** `/data`'s mount wants the unit (a static link in
  `data.mount.wants/`), it does not require it: a reset unit that fails or runs out of
  time does not touch `/data`'s mount. Neither unit of the reset has an `[Install]`
  section, so no first-boot preset enables or disables them.
- **No mount stops the boot.** Every line of `/etc/fstab` has `nofail` and stays ordered
  before `local-fs.target`. A `/data` that cannot be mounted (no filesystem, a broken
  one, a disk that does not answer, a reset that could not make one) leaves its bind
  mounts unmounted, and the device runs on the root slot's own folders
  (`/opt/ironflock`, `/home`, `/var/log`, ...). `ironflockos-data-missing.service` says so in
  capitals on the console, in the journal and in `/run/ironflockos/data-missing`. A IRONFLOCKOS
  partition that cannot be mounted leaves the device without RAUC's `grubenv` and
  without the reset, but online.
- **What the agent needs without /data.** Its folder: the binary (the image has one),
  the `.flock` with the device's identity, the `enrolled` mark and its database. On the
  root slot's own `/opt/ironflock` enroll makes all of them from a `.flock` on the IRONFLOCKOS
  partition, and the agent starts and connects. Docker does not run (its data-root would
  fill the root slot), so the apps do not. The identity is lost with the next update,
  which writes the slot anew, so enroll and `ironflockos-proxy` leave the `.flock` and
  `proxy.conf` on the IRONFLOCKOS partition while `/data` is missing. A device without
  `/data` and without a `.flock` on the partition has no identity and cannot connect:
  its identity was on the `/data` that is gone.

### 3. The request is `factory-reset.conf` on the IRONFLOCKOS partition

- One file, `/boot/efi/factory-reset.conf`. A program running as root writes it, and a
  person can put it there with the boot medium in another computer, as a `.flock` or a
  `proxy.conf`. Only the IRONFLOCKOS partition of the disk the system runs from counts.
- Nothing is cleared when it is written. Removing it cancels it while no attempt has
  begun to erase.
- The content is `KEY=value` lines, `#` comments, LF or CRLF, parsed in the C locale. One
  key so far: `keep-network=yes|no`, default `no`. An empty file is a reset that keeps no
  network settings.
- **A request the device does not understand is refused**, not counted: another key or
  value, a line that is not `KEY=value`, the same key twice with different values, a NUL
  byte, a folder, a file over 4 KiB. Nothing is cleared, the file is renamed to
  `factory-reset.conf.refused`, the record says why, and the device boots as before.
  Ignoring an unknown key (a later "keep the apps", or a typo of `keep-network`) could
  clear what the requester wanted to keep.
- `/usr/lib/ironflockos/factory-reset check FILE` says whether a request is accepted.
- Apps cannot request a reset by accident: the IRONFLOCKOS partition is mounted for root only
  (`umask=0077`), and an app reaches `/boot/efi` only privileged or with a bind of it.
- On the installer stick the reset's units are masked: a request on the stick does not
  run there, and the installer carries only the `.flock` and `proxy.conf` to the disk it
  writes, which is new anyway.

### 4. An attempt

`ironflockos-factory-reset.service` runs `/usr/lib/ironflockos/factory-reset` after the IRONFLOCKOS
partition and `systemd-repart`, before `/data` is checked and mounted, so before
`ironflockos-data-layout`, the bind mounts, `ironflockos-proxy`, `ironflockos-ptp`, containerd, Docker,
the agent and enroll. The script checks the request, the count and the done marks, and
runs the attempt as a second process under its time limit. The attempt works on the data
device resolved once, which must be the partition named `data` on the root slot's disk,
and mounts without following symbolic links.

1. **The kept files go to the IRONFLOCKOS partition.** The old filesystem is mounted
   read-only; RAUC's state (`/data/rauc`) and, with `keep-network=yes`, the network
   settings are copied into `.factory-reset.keep.part`, a tar file. A kept file that
   cannot be read is left out and named in the record.
2. **The try flag, then the name.** On GRUB the booted slot's `<slot>_TRY` is cleared
   when the slot has `<slot>_OK=1` (marked good, or installed and not yet tried), so that
   a power loss brings back this system, which goes on with the reset, rather than the
   other slot's, which may not know it. Then the file is renamed to
   `factory-reset.keep`: the reset has **begun**, and every boot goes on from that file,
   even if the request was removed.
3. **The root slots are cleared** (section 7), the booted one and the other root slot of
   RAUC's `system.conf` when it holds IronFlockOS on the same disk. They come before the
   data partition: an attempt that fails there leaves no account, app file or agent unit
   of the old owner beside a new identity.
4. **The erase.** `erase=started` is written to the state first; then `mkfs.ext4 -F -L
   data -m 0` makes a new filesystem, it is mounted, the kept files are put back with
   their modes and owners, and the done mark is written, with what the record says.
   From the new mount on, a failing step (putting back, `grubenv`, a slot) is named in the
   record (`result=incomplete`), and the reset completes all the same.
5. **The end.** The booted slot's `/etc/machine-id` becomes `uninitialized` (not earlier:
   the running system needs a valid one until it restarts), `factory-reset.keep` and every
   `.factory-reset*.part` are removed, the record is written, the state says done, the
   request is removed last, and the device restarts into a first boot: new machine-id,
   new host keys, `/data` laid out, a `.flock` and a `proxy.conf` on the IRONFLOCKOS
   partition taken in.

A failed attempt that had begun to erase leaves `/data` a new filesystem with the kept
files put back, or, if none can be made, none (section 2). The reset that gives up does
the same, and removes `factory-reset.keep`.

### 5. The `.flock` and `proxy.conf` meanwhile

The reset writes `/run/ironflockos/factory-reset-hold` at each boot it runs, which enroll and
`ironflockos-proxy` read (and `ironflock status` may show):

- `wait`: a request is open and the old owner's data may still be on `/data`: they leave
  the IRONFLOCKOS partition's `.flock` and `proxy.conf` alone, and the old identity runs on,
  from the agent's copy. The new identity never lands on the old data.
- `copy` once the erase has begun: they take the `.flock` and `proxy.conf` but leave them
  on the partition, with the other `.flock` files, for the attempt still to come, which
  erases the agent's copy again. So a device whose attempt failed after the erase comes
  online as the new device. Without `/data` (`/run/ironflockos/data-missing`) they copy too.
- `gave-up`: the reset gave up with the old data and could not remove the `.flock` and
  `proxy.conf` that came for the device after it (a read-only IRONFLOCKOS partition): they
  stay unused, as with `wait`, until the partition can be written and they are removed.
- No file: no reset is open; they are taken as without a reset. Once enroll has enrolled
  from a `.flock` on the partition, it removes every other `.flock` there.

After a give-up with the old data the device is the device it was, online with its old
identity. The `.flock` and `proxy.conf` that came with the request are removed with it; a
`.flock` or `proxy.conf` put on the partition later is taken as on any device.

### 6. Not repart's factory reset, not deleting files: a new filesystem

| | systemd-repart `FactoryReset=` | new filesystem (chosen) | deleting the files |
|---|---|---|---|
| Request | kernel option `systemd.factory_reset=yes` or EFI variable `FactoryReset`; systemd 258's `systemd-factory-reset request` is not in Debian 13 (systemd 257) | a file on IRONFLOCKOS, every target | the same file |
| Targets | needs `repart.d`; Jetson has none; the Pi has no EFI variables | every target: `PARTLABEL=data` is in every fstab | every target |
| Corrupt filesystem | works | works | `rm` fails |
| Time on a large or slow disk | discards and formats | the same (`mkfs.ext4` discards first, lazy inode tables) | a file at a time: many minutes for Docker's layers on an SD card |
| What is left on the disk | discarded | discarded where the disk supports it | the deleted data in free blocks |
| Keep network | out and back: repart deletes the partition | the same, through `factory-reset.keep` | the files stay |

The kept files lie on the IRONFLOCKOS partition for the time of the reset, readable by root
only on the device, because it is shared by both slots and survives a power loss. They
are then overwritten with `shred` and removed; on FAT, and on flash memory with its own
wear levelling, that does not make sure the old content is gone from the medium.

### 7. What is cleared and what is kept

On the data partition everything is cleared except `rauc/` (always: RAUC's record of
each slot, and the Pi tryboot backend's slot states; the A/B update needs it) and, with
`keep-network=yes`, `network/connections/`, `ironflockos/proxy.conf` (ADR-0014) and
`ironflockos/ptp.conf` (ADR-0013). Cleared among the rest: the agent with its `.flock` copy,
Docker's data-root, device-init's `installed.json`, `home/`, `ironflockos/enroll.conf`,
`ironflockos/rt.conf` (with `IRONFLOCKOS_RT_CMDLINE` in `grubenv`), the host keys, the logs, the
downloaded bundles, fwupd's state, the crash records.

In each root slot, in this order: `/apps` removed; `/var/lib/containerd`,
`/var/lib/NetworkManager`, `/var/lib/sudo/lectured`, `/var/tmp` and `/root` emptied
(`/root` gets `.bashrc` and `.profile` from `/usr/share/base-files`); the `ironflock-*`
sudo rules, the agent's unit with its drop-ins and links, `ironflock.slice` and
`/var/lib/ironflockos/enrolled` removed; the accounts with uid or gid 1000 to 59999 removed
from `passwd`, `shadow`, `group`, `gshadow`, `subuid`, `subgid` and their backups; the
hostname set to `ironflockos`; the machine-id `uninitialized` (the booted slot's at the
end). `slot-proven`, the reset's own state and the system stay. Changes the owner made
by hand as root elsewhere in a slot are not undone.

### 8. The record

`/boot/efi/factory-reset.log`, and a copy in the booted slot,
`/var/lib/ironflockos/factory-reset.log`, for when the IRONFLOCKOS partition cannot be written.
`KEY=value` lines, nothing of the old owner: `result=done|incomplete|failed|gave-up|refused`,
the time, image, version, slot and request, the attempt and the attempts allowed, and
what the result needs: what was kept, the other slot, failed steps, the reason, whether
the reset had begun, what `/data` holds, and for `gave-up` in `left=` what of the old
owner may still be on the device. The steps and the reason go to the console and the
journal too, in capitals when the reset gives up or `/data` is missing.

### 9. The contract for `ironflock os reset`

As in [docs/build.md](../build.md#factory-reset), section "The contract for the CLI".

## The lifeline review

Each way the reset can fail or hang, what the device did at 1d848ee, and what it does
now. "Online" means multi-user is reached and the agent can start and connect with the
identity the device has at that boot.

| Failure | Before | Now |
|---|---|---|
| Request unreadable, malformed | refused, online | the same |
| Request or keep file cannot be removed after a completed reset | the reset repeated at every boot, each ending in a restart: never online | done mark in the state and on `/data`: not done again, online |
| Record cannot be written | console only, online | copy in the slot, console, online |
| IRONFLOCKOS read-only before the erase | no reset, online, retried at every boot | three counted attempts, then given up, online |
| IRONFLOCKOS missing or its check fails | emergency mode (fstab) | `nofail`: online without `grubenv` and reset |
| `/data` cannot be unmounted after reading it | no reset, online | failed attempt, online |
| `mkfs.ext4` fails | emergency mode at every boot | failed attempt; `/data` new or missing; online; three attempts |
| `mkfs.ext4` or a mount never returns | the unit waited without limit | limit; failed attempt; online |
| New filesystem cannot be mounted | emergency mode at every boot | as `mkfs.ext4` fails |
| A tool is missing | `set -e`: before the erase online, after it emergency mode | a failed step or attempt, online |
| Root slot full while clearing it | `incomplete`, online | the same, deletions first |
| Root slot cannot take the count | (no count) | no attempt, online |
| `grubenv` unreadable | before the erase: no reset, online; after: failed step | the same, counted |
| Restart cannot be asked for | unit failed: emergency mode | new machine-id, online |
| Power loss at any moment | the next boot went on with the reset; with a failing disk, emergency mode | the next boot is the next attempt; three, then given up; online |
| `/data` cannot be mounted at all | emergency mode | root slot's folders, agent from a IRONFLOCKOS `.flock`, note |
| Raspberry Pi on tryboot | reset waits, online | the same, not counted |
| GRUB boots the other slot mid-reset (`grubenv` lost) | an older system mounts the half-erased `/data` | the same, but the slots are already cleared, and a new `/data` comes first after a failed attempt |
| Jetson | no RAUC backend; the reset's restart counts as one of NVIDIA's three boots | the same |

## Consequences

- `ironflock os reset` writes a file and restarts; the device does the rest.
- A reset takes two restarts. The reset itself takes seconds; a slow disk takes minutes.
- A device always comes up. A reset may give up and leave the old owner's data on the
  device; the record says so (`result=gave-up`, `left=`), and `ironflock os reset` and a
  later status can show it.
- A device whose `/data` is gone runs on its root slot without Docker, and is online
  only with a `.flock` on its IRONFLOCKOS partition; this holds without a reset too.
- The A/B update keeps working: RAUC's state, the `_OK` flags, `ORDER` and `slot-proven`
  stay, and the booted slot stays the bootloader's choice.
- SSH clients see a new host key, DHCP servers a new client.
- Open: Jetson's RAUC backend (WP-6.3); the systemd behaviour of the `nofail` chain and of
  `data.mount.wants/` is shown only in QEMU.
