# ADR-0015: A factory reset, requested on the FLOCKOS partition, makes a new /data at the next boot

Status: accepted, 2026-11-10.

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
unit, the hostname, and `/var/lib/flockos/enrolled`. The device-agent runs apps with
`-appsDir /apps`, which on IronFlockOS is in the root slot too: the apps' own `/data`, their
compose files, build folders and the env files with their secrets. After an A/B update the
other slot still holds the system the device ran before, with the same leftovers.

Every target has to be served: amd64-efi and arm64-efi with GRUB, the Raspberry Pi with
the firmware's tryboot, Jetson with NVIDIA's boot chain, the Compute Engine images. Only
the EFI targets have EFI variables; every target has the FAT partition the `.flock` comes
on (`FLOCKOS`; on Jetson NVIDIA's ESP), mounted at `/boot/efi`.

The root account is locked, so nobody can log in to the emergency mode systemd falls back
to when a mount fails: the console offers only Enter, which tries the same boot again. A
reset must therefore stop the boot only where nothing else is possible.

## Decision

### 1. The request is `factory-reset.conf` on the FLOCKOS partition

- One file, `/boot/efi/factory-reset.conf`. A program running as root writes it, and a
  person can put it there with the boot medium in another computer, as a `.flock` or a
  `proxy.conf`. It works wherever there is a FLOCKOS partition, which is every target.
  Only the FLOCKOS partition of the disk the system runs from counts: one at `/boot/efi`
  on another disk (a stick) cannot ask for a reset.
- Nothing is cleared when it is written. Removing it before the restart cancels it.
- The content is `KEY=value` lines, `#` comments, LF or CRLF, as `proxy.conf`. One key
  so far: `keep-network=yes|no`, default `no`. An empty file is a reset that keeps no
  network settings. The script parses it in the C locale, so the answer is the same
  wherever it runs.
- **A request the device does not understand is refused**: another key, another value,
  a line that is not `KEY=value`, the same key twice with different values, a NUL byte
  (a file a power loss left with zeros), a folder, a file over 4 KiB. Nothing is
  cleared, the file is renamed to `factory-reset.conf.refused` (so a later release that
  understands it does not reset the device by surprise), the record says why, and the
  device boots as before. An unknown key is most likely a later option such as "keep the
  apps", or a typo of `keep-network`; ignoring it would clear what the requester wanted to
  keep. Refusing cannot clear more than was asked for.
- `/usr/lib/flockos/factory-reset check FILE` says whether a request is accepted and what
  it asks for, without changing anything.
- Apps cannot request a reset by accident. The FLOCKOS partition is mounted for root
  only (`umask=0077`). The agent gives an app its own folder as `/data` and binds host
  paths only with privileged access; an app reaches `/boot/efi` only privileged or with a
  bind of it, and then it could change the device in any way anyway, and it would still
  have to write that exact file name. `/data` would be the worse place for the request:
  the reset makes a new filesystem there, and a compose file can bind host paths.
- **While a reset is pending or has begun** (`factory-reset.conf` or `factory-reset.keep`
  on the partition), a `.flock` and a `proxy.conf` there are for the device after it and
  wait: `flockos-enroll` does not take the `.flock` (a slot that is not enrolled yet is
  enrolled from the agent's copy, as the device it still is), `flockos-proxy` does not take
  the `proxy.conf` and keeps the new `.flock`'s hosts out of `NO_PROXY`. Otherwise a boot
  on which the reset waits or fails before it has begun would enroll the new identity on
  the old data. A refused request is renamed before they run; they then take their files
  as without a request.
- Once enroll has enrolled from a `.flock` on the partition, it removes every other
  `.flock` there: each would enroll the device again at the next boot (the unit runs
  whenever one is there).

### 2. The reset runs at the next boot, before /data is mounted

`flockos-factory-reset.service` runs `/usr/lib/flockos/factory-reset` after the FLOCKOS
partition and `systemd-repart`, and before `/data` is checked and mounted, so before
`flockos-data-layout`, the bind mounts, `flockos-proxy`, `flockos-ptp`, containerd, Docker,
the agent, enroll and the persistent journal. `/etc/fstab` makes `/data`'s mount require
the unit (`x-systemd.requires=`), so it needs no `[Install]`. Without a request its
conditions skip it, and so they do when `/data` is mounted: a unit that needs `/data`
started later pulls it in again, and the reset is for a boot only. The script checks the
same and exits without a record.

Before it acts, the script resolves `/dev/disk/by-partlabel/data` once and works on that
device only; it must be the partition named `data` on the disk of the root slot, and the
FLOCKOS partition at `/boot/efi` must be on that disk too. A disk plugged in later cannot
take over the link.

1. **The kept files go to the FLOCKOS partition.** The old filesystem is mounted
   read-only and without following symbolic links (`nosymfollow`); RAUC's state
   (`/data/rauc`) and, with `keep-network=yes`, the network settings are copied into
   `factory-reset.keep`, a tar file written under the name `.factory-reset.keep.part`.
   A kept file that cannot be read is left out and named in the record. Then the booted
   slot's try flag is cleared (section 3) and the file takes its name: from then on the
   reset has **begun**.
2. **A new filesystem** on the data partition: `mkfs.ext4 -F -L data -m 0`, the label
   repart gives it. It is mounted, and the kept files are put back with their modes and
   owners.
3. **The root slots are cleared** of what the enrollment, the agent, apps and users leave
   there (the inventory below): the booted slot, and the other root slot of RAUC's
   `system.conf` when it holds an IronFlockOS system on the same disk, mounted without
   following symbolic links. The deletions come first: they make room in a slot apps
   have filled.
4. **The end.** `factory-reset.keep` and every `.factory-reset*.part` on the partition are
   removed, the record `factory-reset.log` is written, the request is removed last, and
   the device restarts. The boot after that is a first boot: `/etc/machine-id` says
   `uninitialized`, so systemd makes a new one; `flockos-ssh-hostkeys` makes new host keys;
   `flockos-data-layout` the folders of `/data`; `flockos-proxy` takes a `proxy.conf` from
   the FLOCKOS partition; `flockos-enroll` runs, as `enrolled` is gone, with a `.flock` on
   the FLOCKOS partition, or tells that the device stays unenrolled; on Compute Engine
   `flockos-gce-flock` runs again.

The restart is part of the reset: systemd read the machine-id and the hostname before the
reset ran, and the journal of that boot belongs to the old identity. The steps go to the
console as well (`journal+console`): that boot's journal never reaches `/data`.

### 3. Failures and a power loss at any moment

Every step can run again, and the request is removed last.

- **Until `factory-reset.keep` has its name** the data partition is untouched. A failure
  (no data partition, the wrong partition or disk, no room on the FLOCKOS partition, a
  `grubenv` that cannot be read or written) clears nothing: the unit succeeds, the device
  boots as before, the record says why (`result=failed`, `begun=no`), and the next boot
  tries again. A try flag the reset had cleared is set again. A power loss starts the
  reset over at the next boot.
- **Once it has its name** every boot goes on with the reset, from that file, even if the
  request was removed in the meantime (the unit also runs when only `factory-reset.keep`
  is there). Only a new filesystem that cannot be made or mounted stops the boot: the
  unit fails, `/data` is not mounted, and nothing that uses it starts, so the device never
  comes up as a normal device on a half-cleared `/data`. It stops in emergency mode, the
  reason on the console, where nobody can log in; Enter or a power cycle tries again.
- **Every later step is done as far as it goes**: putting back the kept files, clearing
  the booted slot and the other slot, `grubenv`, removing `factory-reset.keep` and the
  part files. A step that fails is named in the record (`result=incomplete`,
  `failed-steps=`), the request is removed all the same, and the device restarts into its
  first boot. What is left over is in a root slot or on the FLOCKOS partition, not on the
  new `/data`; the old SSH user's home and keys were on `/data` and are gone.
- **A data partition that cannot be mounted** (a corrupt filesystem) is reset all the
  same, keeping nothing of it, and the record says so. Such a device would not come up
  anyway.
- **A FLOCKOS partition that cannot be written** stops the reset before it begins. If it
  becomes read-only during the reset, the request and `factory-reset.keep` cannot be
  removed, and the next boot resets again from the same kept files. This is accepted: a
  reset whose files are still there counts as begun, and one that has begun finishes.
  Each such reset ends in a restart, so the device does not come up until the partition
  can be written again; `fsck.vfat` checks and repairs it at every boot. Nothing outside
  the FLOCKOS partition records that a reset is finished, so nothing ends the repeat on a
  partition that stays read-only: such a device has to be flashed again.
- **The same system goes on.** The other slot may hold an older IronFlockOS that knows no
  reset and would mount the half-cleared `/data`. On GRUB every boot counts as a try of
  its slot until it is marked good, so a power loss, or the reset's own restart, would
  move the device to its other slot, or back to a slot that had failed. Just before the
  reset begins, it clears the booted slot's `<slot>_TRY` flag in `grubenv` when the slot
  has `<slot>_OK=1`: the next boot is this slot again. RAUC sets `_OK=1` both on a slot
  marked good and on one it has just installed and not yet tried; such a slot gets one
  more try. A reset that has begun clears the flag again at every boot it goes on; there a
  `grubenv` that cannot be read or written is a failed step, not a stop. The reset changes
  no `_OK` flag and no `ORDER`, so RAUC keeps both slots as they were. On the Raspberry Pi
  a plain restart boots the committed slot; a system that runs on trial (tryboot) leaves
  the reset to the next boot that is not a trial, as a power loss would end the trial.
  Jetson's RAUC backend is not built yet (WP-6.3); NVIDIA's firmware falls back after
  three failed boots, and the reset's restart counts as one.

### 4. Not repart's factory reset, not deleting files: a new filesystem

| | systemd-repart `FactoryReset=` | new filesystem (chosen) | deleting the files |
|---|---|---|---|
| Request | kernel option `systemd.factory_reset=yes` or EFI variable `FactoryReset`; systemd 258's `systemd-factory-reset request` (EFI variable `FactoryResetRequest`) is not in Debian 13 (systemd 257) | a file on FLOCKOS, every target | the same file |
| Targets | needs `repart.d`; Jetson has none (NVIDIA's flash writes the layout); the Pi has no EFI variables, and the kernel command line lives in a different file per target | every target: `PARTLABEL=data` is in every fstab | every target |
| Corrupt filesystem | works (the partition is made anew) | works | `rm` fails, the reset never ends |
| Time on a large or slow disk | discards and formats: seconds, minutes for some SD cards | the same (`mkfs.ext4` discards the partition first, lazy inode tables) | a file at a time: many minutes for Docker's layers on an SD card |
| What is left on the disk | discarded | discarded where the disk supports it | the deleted data in free blocks |
| Keep network | out to somewhere else and back: repart deletes the partition | the same, through `factory-reset.keep` | the files stay where they are |
| Power loss | the partition may be gone; repart makes it on the next boot | a new filesystem again | deletes on |

repart's factory reset would re-create the partition, which a new filesystem on it does
not need, and it cannot serve Jetson. Deleting files is slow, cannot cope with a corrupt
filesystem, and leaves data behind. The cost of a new filesystem is a place for the kept
files while it is made: RAM would lose them at a power loss, and the root slot is the
booted slot's only, which the other slot cannot read if the device ever boots it during a
reset. The FLOCKOS partition is shared by both slots and survives. The kept files lie
there for the seconds of the reset, as a `.flock` or `proxy.conf` does until it is taken,
readable by root only on the device. Afterwards the file is overwritten with `shred` and
removed. On FAT, and on flash memory with its own wear levelling, that does not make sure
the old content is gone from the medium: until the blocks are written again, someone who
reads the raw medium may find the WiFi password and the proxy's.

### 5. What is cleared and what is kept

On the data partition everything is cleared except:

| Path on `/data` | Kept | Why |
|---|---|---|
| `rauc/` (RAUC's `data-directory`) | always | RAUC's record of each slot (bundle, version, installed and activated times), which `ironflock os` reads, and on the Pi the tryboot backend's slot states. Not the owner's; the A/B update needs it |
| `network/connections/` (`/etc/NetworkManager/system-connections`) | with `keep-network=yes` | the network profiles, the `.flock`'s WiFi among them |
| `flockos/proxy.conf` (ADR-0014) | with `keep-network=yes` | the proxy and NTP servers of the site |
| `flockos/ptp.conf` (ADR-0013) | with `keep-network=yes` | the PTP role on the machine network, a setting of the site |

Cleared, among the rest: `ironflock/` (the agent with its `.flock` copy, database and
`enrolled`; Docker's data-root with images, containers and volumes; device-init's
`installed.json`), `home/`, `flockos/enroll.conf`, `flockos/rt.conf` (the platform's
real-time tuning; `FLOCKOS_RT_CMDLINE` in `grubenv` goes with it, so the next boot runs
the image's defaults, as a flashed device does), `etc/ssh/` (host keys), `log/` (journal,
agent logs), `cache/` (downloaded bundles), `fwupd/` (fwupd's history and pending
updates: a capsule fwupd has staged on the FLOCKOS partition still applies at the next
restart, fwupd no longer knows of it), `pstore/` (crash records), and anything else.

In each root slot, in this order:

| Path | Reset | Why |
|---|---|---|
| `/apps` | removed | the agent's `-appsDir`: the apps' files and secrets |
| `/var/lib/containerd`, `/var/lib/NetworkManager`, `/var/lib/sudo/lectured`, `/var/tmp` | emptied | containerd's state, DHCP leases and NetworkManager's secret key, sudo's per-user records, temporary files |
| `/root` | emptied, then `.bashrc` and `.profile` from `/usr/share/base-files` | root's home, which the SSH user reaches with sudo |
| `/etc/sudoers.d/ironflock-*` | removed | the SSH user's sudo rule |
| `/etc/systemd/system/ironflock-device-agent.service`, its `.d/`, its `.wants` links, `ironflock.slice` | removed | the agent's unit, which enroll installs |
| `/var/lib/flockos/enrolled` | removed | so enroll (and `flockos-gce-flock`) run as on a first boot |
| accounts with uid or gid 1000 to 59999 in `passwd`, `shadow`, `group`, `gshadow`, `subuid`, `subgid` and their backups (`passwd-` and the others), and their names in other groups | removed | the `.flock`'s SSH user; the image has no such account (`build/customize.sh`). The backups are rewritten the same way, as shadow-utils keeps the account there too |
| `/etc/hostname`, the `127.0.1.1` line of `/etc/hosts` | `flockos` | the image's; enroll sets the `.flock`'s name |
| `/etc/machine-id` | `uninitialized` | a new one at the slot's next boot, as on a first boot |
| `/var/lib/flockos/slot-proven` | kept | that the system in the slot has proven itself, which `flockos-slot-keep` needs; it belongs to the system, not the owner |
| the rest: `/usr`, the image's `/etc` (Docker's `daemon.json`, the NetworkManager and dbus drop-ins of `ironflock-init bake`), `/var/lib/chrony`, `/var/cache/ironflock` | kept | the system |

The other slot gets the same, so a rollback after a reset boots no old identity: its
enroll runs again, from the new agent copy. Its system is no longer byte for byte the
bundle it came from; the next update writes it anew anyway. A slot without a filesystem
(slot B before the first update), on another disk or without IronFlockOS is left as it
is; one that has a filesystem that cannot be mounted, or that cannot be cleared, is a
failed step.

On the FLOCKOS partition the reset writes `factory-reset.log`, changes `grubenv` as
described (the booted slot's `_TRY`, `FLOCKOS_RT_CMDLINE`), removes `.factory-reset*.part`
files, and keeps the rest: boot files, `ORDER` and the `_OK` flags, `FLOCKOS_CMDLINE`
(diagnosis, the QEMU test's shell), `autoboot.txt`, a waiting `.flock` and `proxy.conf`.

Not covered: changes the owner made by hand as root elsewhere in a root slot (a package,
a file in `/etc`, a unit). An update replaces the slot; a reflash replaces everything.

### 6. The record

`/boot/efi/factory-reset.log`, replaced by every reset and every refusal, `KEY=value`
lines: `result=done|incomplete|refused|failed`, the time by the device's clock, the image
and version, the booted slot; for `done` and `incomplete` the request's `keep-network`,
what was kept, what happened in the other slot and a `note` when something could not be
kept, and for `incomplete` the `failed-steps`; for `refused` and `failed` the `reason`,
and for `failed` whether the reset had `begun`. It names nothing of the old owner: no
device name, user, network name or proxy. It is on the FLOCKOS partition because after a
reset without a new `.flock` nobody can log in: a person reads it with the medium in
another computer, the console shows the same steps, `ironflock status` reads it once
someone can log in, and the QEMU test reads it. A reset that waits (tryboot) or runs while
`/data` is mounted writes none.

### 7. The contract for `ironflock os reset`

As in [docs/build.md](../build.md#factory-reset), section "The contract for the CLI".

## Consequences

- `ironflock os reset` writes a file and restarts; the device does the rest, the same way
  for a person who puts the file there by hand.
- A reset takes two restarts. The reset itself takes seconds; the discard of a large
  partition on a slow SD card or eMMC can take minutes.
- After a reset without a new `.flock` the device is reachable on the console only, as a
  freshly flashed one. With `keep-network=yes` it is on its network again, ready for a
  `.flock`.
- The A/B update keeps working: RAUC's state, the `_OK` flags, `ORDER` and `slot-proven`
  stay, and the booted slot stays the bootloader's choice.
- SSH clients see a new host key, DHCP servers a new client (the machine-id changed).
- A reset whose clean-up of a root slot fails (a full or damaged slot) still ends in a
  first boot on a new `/data`; the record names what is left to do.
- The root slots' leftovers are cleared by a list. What a later release of the agent or of
  device-init writes elsewhere into a slot has to be added to it.
- A system without the reset (IronFlockOS up to 0.14) ignores a request and takes a
  waiting `.flock`: the requester makes sure the next start is a system that has it.
- Open: Jetson's RAUC backend (WP-6.3) has to keep the slot the reset runs in; the reset
  touches no try counter there yet.
