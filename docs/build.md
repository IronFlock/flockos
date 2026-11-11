# Building IronFlockOS images

Every IronFlockOS image is built by `just build TARGET VARIANT [KERNEL]` inside a
pinned Debian 13 container (`build/builder.conf`). CI runs exactly that, and CI
is the build of record: release images are built, signed and published only by
`.github/workflows/release.yml`. A local build with Docker exists for debugging
and produces the same image, except for its signing keys.

## Stages

`build/run-in-builder.sh` runs on the host. It reads version, commit and commit
time from git and starts the build container with the repository mounted
read-only at `/src`, a scratch volume at `/work` and the artefact directory at
`/out`. Inside, `build/in-builder.sh` installs the build tools
(`build/builder-packages`) and runs `build/build.sh`, which calls one script per
stage:

| Stage | Script | Result |
|-------|--------|--------|
| signing material | `build/signing.sh` | `keyring.pem` the image trusts, the signer certificate and key. Throwaway by default; a release build (`FLOCKOS_SIGNING=release`) puts the IronFlockOS root CA into the image and seals the bundle with a throwaway key for `release.yml`'s sign job (ADR-0006, `docs/signing.md`) |
| rootfs | `build/mkrootfs.sh` | minbase tree of the target's distribution (see below) from `mmdebstrap` with `profiles/base/packages`, its per-distribution and per-architecture lists, the target's `targets/<target>/packages` and the variant's `profiles/<variant>/packages` (no Recommends), Docker CE from download.docker.com at the versions in `distros/<distro>/versions`; for `nvidia` also NVIDIA's driver, its open kernel modules and the container toolkit (see below) |
| customisation | `build/customize.sh` | `overlay/` copied in, RAUC `system.conf` and keyring, `repart.d`, os-release, no accounts but a locked root, kernel at `/vmlinuz`, units enabled and masked, IronFlock baked in (`build/bake.sh`; not into the installer), package manifest, timestamps clamped to the commit time |
| disk image | `build/mkimage.sh` (EFI targets), `build/mkimage-rpi.sh` (Raspberry Pi: FLOCKOS with `autoboot.txt`, boot-a from `/boot/firmware`, an empty boot-b, slot A) | FLOCKOS partition (ESP: shim, Debian's signed GRUB, `grub.cfg`, `grubenv`), slot A as ext4 of the full slot size, assembled by `genimage` from `targets/<target>/genimage.cfg`, compressed |
| bundle | `build/mkbundle.sh` | verity RAUC bundle of slot A's filesystem, `compatible=flockos-<target>-<variant>[-rt]`, signed and verified against the image keyring (none for the installer); on `rpi-arm64` with the boot partition as `boot.vfat` |

### The distribution

A target's `target.conf` may name its distribution as `DISTRO`; without one it
is `debian-trixie`, the userspace of every image so far. `distros/<distro>/versions`
holds what `mkrootfs.sh` needs of it, as plain `KEY=value` data:

| Key | Debian 13 (`debian-trixie`) | Ubuntu 24.04 (`ubuntu-noble`) |
|-----|-----------------------------|-------------------------------|
| `DISTRO_ID`, `DISTRO_ID_LIKE` | `debian`, `debian` | `ubuntu`, `ubuntu debian` |
| `DISTRO_SUITE` | `trixie` | `noble` |
| `DISTRO_MIRROR`, `DISTRO_SECURITY_MIRROR` | deb.debian.org | ports.ubuntu.com (arm64) |
| `DISTRO_KEYRING` | `debian-archive-keyring.gpg` | `ubuntu-archive-keyring.gpg` |
| `DOCKER_MIRROR` and the Docker pins | `linux/debian`, `~debian.13~trixie` | `linux/ubuntu`, `~ubuntu.24.04~noble` |

The device keeps the distribution's sources as
`/etc/apt/sources.list.d/<id>.sources`, signed by the keyring of its
archive-keyring package. `ID_LIKE` in os-release is `DISTRO_ID_LIKE`.
`profiles/base/packages.<id>` adds what only one distribution has or names its
own way; on Debian that is `systemd-repart` (Ubuntu 24.04 ships it in `systemd`)
and the `firmware-*` packages. Ubuntu noble is the userspace of `jetson-orin`
(ADR-0008, `docs/targets/jetson-orin.md`). Its image stage
(`build/mkimage-tegra.sh`) makes slot A's filesystem image, as NVIDIA's flash
tools write a Jetson's disk. The nvidia variant is built on Debian only.

Artefacts land in `out/<image-id>/`:

| File | What |
|------|------|
| `<image-id>-<version>.img.gz` | the disk image FlockFlasher writes |
| `<image-id>-<version>.raucb` | the update bundle |
| `<image-id>-<version>.packages.tsv` | every Debian package in the image with its version |
| `<image-id>-<version>.sources.tsv` | the source packages of the image, from which the release publishes their source ([release.md](release.md#source-code)) |
| `<image-id>-<version>.os-release` | the image's `/etc/os-release` |
| `SHA256SUMS` | checksums of the image and the bundle |

## Disk layout on a device

The image holds the FLOCKOS partition and slot A only. On the first boot
`systemd-repart` (definitions in `targets/<target>/repart.d/`) creates slot B
with the same size and the `data` partition over the rest of the disk, and
formats `data`. `/etc/fstab` mounts `data` at `/data` and bind-mounts the
persistent paths from it (master plan, section 3.2). No mount there can stop
the boot (`nofail`, each still ordered before `local-fs.target`): a device
whose `/data` cannot be mounted runs on the root slot's own folders, without
Docker, and `flockos-data-missing` says so on the console and in
`/run/flockos/data-missing` (ADR-0015).

| Path | From |
|------|------|
| `/opt/ironflock` | `/data/ironflock` (agent, `.flock` copy, Docker data-root) |
| `/home` | `/data/home` |
| `/etc/NetworkManager/system-connections` | `/data/network/connections` |
| `/var/log` | `/data/log` (the journal and every other log: logs never fill the fixed-size root slot) |
| `/var/cache/flockos` | `/data/cache` (downloaded bundles) |
| `/var/lib/fwupd` | `/data/fwupd` |
| `/var/lib/systemd/pstore` | `/data/pstore` (what the kernel recorded about a crash, kept across updates) |

SSH host keys are made on the first boot in `/data/etc/ssh` and `sshd` is
pointed there. The machine-id is generated on the first boot in the slot; RAUC's
post-install handler (`/usr/lib/flockos/rauc-post-install`) copies it and the
hostname into the slot it has just written, so an update keeps the device's
identity. On Jetson it also points that slot's `extlinux.conf` at the slot
(`docs/targets/jetson-orin.md`). RAUC's own state is in `/data/rauc`.

### Slot size

A slot's size (`SLOT_SIZE_<VARIANT>` in `target.conf`) is fixed for a device's
lifetime: slot B and `data` are created once, on the first boot, and an update
rewrites a slot's contents, never its partition. Every later release of an image
must therefore fit the slots of the oldest device in the field. The image stage
checks the slot filesystem it has made (`check_slot_fill` in `build/lib.sh`,
from the ext4 superblock, ext4's overhead included): it warns, and annotates the
CI run, from 75% full, and fails the build from 90%
(`FLOCKOS_SLOT_FILL_WARN`, `FLOCKOS_SLOT_FILL_MAX`). v0.10.0's trees fill about a
third of their slots (1.2 to 1.4 GiB of 4 GiB, 2.1 GiB of nvidia's 8 GiB).
Outgrowing a slot takes a new image id with a larger slot, not a bundle.

## Boot and A/B

The boot chain is Debian's signed one (ADR-0011), from the image's packages:
the firmware starts shim (`shim-signed`, signed by Microsoft) at the
removable-media path `EFI/BOOT/BOOTX64.EFI` (`BOOTAA64.EFI` on arm64; no boot
entry is needed), shim starts and checks Debian's signed GRUB next to it
(`grubx64.efi`), and GRUB has shim check Debian's kernel. With Secure Boot off
the same chain boots without the checks. Debian's GRUB has its modules built
in and reads `grub.cfg` next to itself, in `EFI/BOOT` (else its prefix's
`EFI/debian/grub.cfg`, which `build/mkimage.sh` writes to source the same
script); the script points `${prefix}` at `EFI/BOOT`, where `grubenv` is. `grub.cfg`
(`targets/amd64-efi/grub/grub.cfg`) is RAUC's reference A/B script: it picks the
first slot in `ORDER` that is good and not yet tried, sets its `_TRY` flag in
`grubenv`, and boots that slot's `/vmlinuz` with `root=PARTUUID=…` and
`rauc.slot=A|B`. A slot that is never marked good is skipped on the next boot.
The device-agent marks the booted slot good once it has reached the platform
(device-agent 1.6.0); nothing in the image does it at boot for a new system.
That first mark proves the slot: `flockos-slot-proven` leaves a file in the
slot's own root filesystem, which an update replaces. A slot with that file is
marked good again once it has stayed up for two minutes after reaching
`multi-user.target` (`flockos-slot-keep.timer`), so a restart without a
connection does not move the device to its other slot, and a slot that fails
within those two minutes still falls back. A device that never
reaches the platform keeps booting its good slot: when every slot has been
tried, GRUB starts over with the first good one.

`FLOCKOS_CMDLINE` in `grubenv` appends kernel parameters on both slots, for
diagnosis in the field (`grub-editenv /boot/efi/EFI/BOOT/grubenv set
FLOCKOS_CMDLINE=...`) and for the QEMU tests.

Known limit of 1.x: slots are found by GPT partition name (`rootfs-a`,
`rootfs-b`, `data`) and every image of a target has the same partition UUIDs.
A second IronFlockOS disk attached to a running device is therefore ambiguous; the
installer USB uses its own names.

## IronFlock in the image

`build/bake.sh` fetches `ironflock-init` at the version pinned in
`profiles/base/versions`, checks its OpenPGP signature against device-init's
bootstrap key (`profiles/base/keys`, pinned by SHA-256), and runs
`ironflock-init bake` on the tree: the verified agent of the production channel,
Docker's `daemon.json`, the NetworkManager and dbus restart drop-ins, the login
banner, and `ironflock-init` itself. The agent version goes into
`<image-id>-<version>.ironflock.json`.

On the device `flockos-enroll.service` runs `ironflock-init enroll` on the first
boot of every slot and whenever a `.flock` lies on the FLOCKOS partition: with
the newest `.flock` there (removed afterwards, and every other `.flock` there
with it, as each would enroll the device again), else with the agent's own copy
on `/data`. While a factory reset may still find the old owner's data on
`/data`, a `.flock` there waits; once it has begun to erase, or without
`/data`, enroll takes it and leaves it there ("Factory reset"). An A/B update
brings a slot without the SSH user and the agent's unit; enroll puts them back without network. Enroll also sets the hostname
from the device name in the `.flock` (ADR-0009), made into a valid hostname by
`ironflock-init`. A device keeps its hostname with `hostname-from-flock=no` in
`/etc/flockos/enroll.conf`, which links to `/data/flockos/enroll.conf` and so
outlives updates.

The device-agent marks the booted slot good once it has reached the platform
(WP-2.4, device-agent 1.6.0); a slot it never marks falls back.

## Time

chrony keeps the clock on every image ([ADR-0013](adr/0013-chrony-keeps-the-time-ptp-per-device.md)).
It uses the distribution's NTP pools and the NTP servers DHCP hands out
(NetworkManager passes them to chrony).
`chronyd -s` (`/etc/default/chrony`) starts the clock from the real-time clock or,
on a board without one, at the time chronyd last stopped, as systemd-timesyncd
did with its clock file. `chronyc tracking` and `chronyc sources` show the state.

PTP is a device setting. `/etc/flockos/ptp.conf` links to
`/data/flockos/ptp.conf`, so it outlives updates:

```ini
interface=enp88s0   # the interface for PTP; without it PTP is off
role=client         # client (default) or server, see below
domain=0            # 0 to 255
transport=udp4      # udp4, udp6 or l2
delay=e2e           # e2e or p2p
priority1=64        # role=server only: the priority it announces; lower wins
```

`flockos-ptp` reads it at boot, before chrony starts, and again whenever the
file changes (`flockos-ptp.path`): a change applies within seconds, without a
reboot. With an interface, `flockos-ptp4l` runs PTP on it and `flockos-phc2sys`
moves the time between that interface's hardware clock and the system clock.
Apps read the clock; none needs `SYS_TIME` or `/dev/ptp*` for it.

- **client:** `ptp4l` keeps the hardware clock on the master's time and never
  becomes a master itself. `phc2sys` hands that time to chrony's PTP source
  through a socket, only while `ptp4l` follows a master (the flags linuxptp's
  `timemaster` uses for chrony). chrony selects PTP over NTP, whose error is far
  larger, and falls back to NTP when the samples stop. So a device without
  internet access keeps PTP time, and a device whose master goes away keeps
  NTP time.
- **server:** `ptp4l` is the master on the interface and never takes time from
  it; devices there, such as cameras, follow it. `phc2sys` keeps the hardware
  clock on the system clock, which chrony keeps on NTP. It waits up to two
  minutes for chrony's first synchronisation, so the clients do not see the
  boot's correction; without NTP it serves the clock as it runs. Clocks ship
  with `priority1` 128, and the lower value wins, so the default 64 makes the
  device the master against them; on a tie the lowest clock identity would
  win. A later correction of the system clock reaches the clients too.

`ptp4l` needs an interface with hardware time stamps (`ethtool -T <interface>`);
the journal of `flockos-ptp4l` says when it has none. `chronyc sources` lists
`#* PTP` while a client keeps PTP time; `journalctl -u flockos-ptp4l -u flockos-phc2sys`
and `pmc -u -b 0 -d <domain> 'GET CURRENT_DATA_SET' 'GET PARENT_DATA_SET'`
(`offsetFromMaster`; a server's own `clockIdentity` as `grandmasterIdentity`)
show the PTP side.

## Proxy

A site that reaches the internet only through a proxy sets it in
`/etc/flockos/proxy.conf`, which links to `/data/flockos/proxy.conf`, so it
outlives updates ([ADR-0014](adr/0014-proxy-per-device-from-the-flockos-partition.md)):

```ini
http_proxy=http://proxy.corp.example:3128   # http://, https://, socks5:// or socks5h://
https_proxy=http://proxy.corp.example:3128  # default: http_proxy
no_proxy=10.0.0.0/8,.corp.example           # reached directly, comma-separated
ntp=10.0.0.1,ntp.corp.example               # NTP servers, where NTP to the internet is blocked
```

A user and password go into the URL, percent-encoded
(`http://user:p%40ss@proxy:3128`). The file may hold them: it is readable by
root only, and the log shows the URL without them.

A device behind a proxy cannot reach the platform before it knows the proxy, so
the file comes with the boot medium: a `proxy.conf` on the FLOCKOS partition,
next to the `.flock` (FlockFlasher writes it), replaces the device's on the next
boot and is removed from the partition; during a factory reset it waits, or is
taken and left there, as the `.flock` is ("Factory reset"). The installer stick passes its
`proxy.conf` on to the disk it installs, and keeps it for the next device. On a
device that runs, editing `/etc/flockos/proxy.conf` applies within seconds.

`flockos-proxy` turns the file into `/run/flockos/proxy.env` at boot, before
containerd, Docker, the device-agent and chrony start, and again whenever the
file changes (`flockos-proxy.path`), restarting those that run. Drop-ins in the
image hand the file to the three services: the agent uses the proxy for its
platform connection, its downloads (OS updates, firmware, agent updates) and
remote-access tunnels, and passes it to the apps it starts; Docker and
containerd pull images through it. An app that runs gets the proxy when the
agent next creates it.

`NO_PROXY` holds `localhost`, `127.0.0.1` and `::1`, then the hosts the
device-agent's own installer keeps off a proxy, from the device's `.flock`: the
appliance's domain and its subdomains, and the LAN registries
(`insecure-registries` and a `docker_registry_url` with a port), and then
`no_proxy`. A proxy cannot reach back into the LAN, so an appliance behind it
would be out of reach. A host reached by name needs its name in `no_proxy`, not
its address.

NTP does not pass an HTTP proxy, and without the right time TLS through the
proxy fails. chrony already uses the NTP servers DHCP hands out; `ntp=` adds
servers for networks that hand out none (`chronyc sources` lists them).

## Factory reset

A factory reset returns a device to the state of a freshly flashed one that
waits for a `.flock` ([ADR-0015](adr/0015-factory-reset-requested-on-the-flockos-partition.md)).
It is requested by the file `factory-reset.conf` on the FLOCKOS partition and
runs at the next boot, before `/data` is mounted:

```ini
keep-network=yes   # keep the network profiles, proxy.conf and ptp.conf (default no)
```

`flockos-factory-reset` (`/usr/lib/flockos/factory-reset`) copies what is kept
into `factory-reset.keep` on the FLOCKOS partition, clears what the
enrollment, the agent, apps and users left in both root slots, makes a new
filesystem on the data partition, puts the kept files back, writes
`factory-reset.log`, removes the request and restarts. What is kept: RAUC's
state (`/data/rauc`) always; with `keep-network=yes` also
`/data/network/connections`, `/data/flockos/proxy.conf` and
`/data/flockos/ptp.conf`. Everything else on `/data` goes. In the root slots
the reset removes `/apps`, containerd's and NetworkManager's state, root's
files, the sudo rule and the agent's unit, `/var/lib/flockos/enrolled` and the
accounts the enrollment made, and sets the hostname back to `flockos` and the
machine-id to `uninitialized`; `slot-proven`, `ORDER` and the `_OK` flags of
`grubenv` stay. ADR-0015 lists every path. The boot after the reset is a first
boot: new machine-id and host keys, `/data` laid out anew, a `proxy.conf` and a
`.flock` on the FLOCKOS partition taken in.

No failure of the reset keeps a device offline. Each request has three
attempts, counted in `/var/lib/flockos/factory-reset.state` of the booted slot
before each starts. A failed attempt is recorded, and the boot goes on with
what `/data` holds; the next boot tries again. After the third failure the
reset gives up: the device boots with the old `/data`, or a new one when the
reset had begun to erase it, and the record says what of the old owner may be
left. Every step that waits on a disk has a time limit; an attempt has 25
minutes in all. The reset restarts the device only after it has completed,
and a completed reset is marked done in the state and on the new `/data`, so it
is never done twice. Where the count cannot be written there is no attempt.
A request that ended never fires again: a given-up request is renamed to
`factory-reset.conf.gave-up`, its outcome is marked on `/data`, and the state
goes with every update into the new slot. After a give-up with the old data
the device stays the device it was; the `.flock` and `proxy.conf` that came
with the request are removed. `/run/flockos/factory-reset-hold` tells enroll
and `flockos-proxy` what to do with the FLOCKOS partition's `.flock` and
`proxy.conf`: leave them (`wait`, a request is open and the old owner's data
may be on `/data`; `gave-up`, they could not be removed after a give-up), or
take them and leave them there (`copy`, once the erase has begun). A request the
device does not understand is refused, not counted, and renamed to
`factory-reset.conf.refused`. On a Raspberry Pi that runs an update on trial,
the reset waits for the next boot that is not a trial. The steps are on the
console and in the journal; `factory-reset.log` keeps the result.

### The contract for the CLI

`ironflock os reset [-c new.flock] [--keep-network]` (device-init) is written
from this section.

- **Support.** The device can reset when `/usr/lib/flockos/factory-reset`
  exists.
- **`check`.** `/usr/lib/flockos/factory-reset check FILE` changes nothing.
  - Exit 0: FILE is a request the device accepts. stdout is exactly one line,
    `keep-network=yes` or `keep-network=no`.
  - Exit 1: refused. stderr is one line, `factory-reset: <reason>`, without the
    file's name. The reasons: `the request is not a file`, `the request is
    larger than 4 KiB`, `the request holds a NUL byte`, `line <n> is not a
    key=value line`, `line <n>: keep-network must be yes or no`, `line <n>:
    keep-network is given twice, with different values`, `line <n>: unknown key
    <key>`.
  - Exit 2: wrong arguments.
- **The request.** `/boot/efi/factory-reset.conf`, on the FLOCKOS partition of
  the disk the system runs from, mounted at `/boot/efi` (on Jetson NVIDIA's
  ESP). It is FAT, mounted for root only: every file there has mode 0700 and
  belongs to root, whatever the writer asks for. Text, at most 4 KiB, no NUL
  byte, `KEY=value` lines; `#` starts a comment, also after a value; LF or
  CRLF. One key: `keep-network=yes|no`, default `no`. Write `keep-network=yes\n`
  or `keep-network=no\n`; an empty file is a reset with `keep-network=no`. The
  device refuses any other key or value; a new key comes with a release of
  IronFlockOS, and `check` tells whether a device knows it.
- **Which request.** The device tells a request from another one by its
  checksum, size and time of change. Each request has three attempts. One that
  was completed or given up never fires again, in any slot and after any
  update: a completed one is removed, a given-up one is renamed to
  `factory-reset.conf.gave-up` (on a read-only FLOCKOS partition, at the first
  boot it can be written), and both are marked on `/data` and in the state,
  which an update carries into the new slot. To try again, write a new
  request.
- **The hold.** `/run/flockos/factory-reset-hold`, written at each boot the
  reset runs: `wait` (a request is open; the FLOCKOS partition's `.flock` and
  `proxy.conf` stay unused while the old owner's data may be on `/data`),
  `copy` (a request is open and has begun to erase; they are used and stay),
  `gave-up` (the reset gave up with the old data and could not remove them;
  they stay unused); no file: no request is open, they are used as on any
  device. After a give-up with the old data the device is the device it was,
  and the `.flock` and `proxy.conf` that came with the request are removed.
- **Before writing.** The next start must run a system that has the reset: the
  running system must be the bootloader's next choice and marked good (`rauc
  status`: the booted slot is `boot_primary` and its `boot_status` is `good`),
  no update or rollback waiting, and on a Raspberry Pi no tryboot armed. On a
  start of a system that has the reset but runs on trial (Raspberry Pi
  tryboot), the request, the `.flock` and the `proxy.conf` wait for the next
  start that is not a trial. A system without the reset (IronFlockOS up to
  0.14) ignores the request and takes a waiting `.flock` and `proxy.conf` as
  usual: the new identity would run on the old data.
- **Writing it.** As root: the whole content to a temporary name in the same
  folder, any `/boot/efi/.factory-reset*.part` (for example
  `.factory-reset.conf.part`), fsync, `check` it if you like, rename to
  `factory-reset.conf`, fsync the folder. The reset removes every
  `.factory-reset*.part` there when a request ends (done, incomplete, gave-up or
  refused).
- **A new device (`-c`).** After the request, write the new `.flock` the same
  way (for example `.factory-reset.flock.part`) and rename it to
  `/boot/efi/<name>.flock`. Remove every other `*.flock` on the partition first:
  enroll takes the newest one by modification time, which FAT keeps to two
  seconds. If the `.flock` cannot be written, remove the request again. A
  `proxy.conf` for the new site goes to `/boot/efi/proxy.conf` the same way.
  While the old owner's data may still be on `/data`, neither is taken: the
  new identity never runs on the old data. After a failed attempt that had
  begun to erase, both are taken and left on the partition, so the device
  comes online as the new device before the next attempt. After a completed
  reset enroll takes the `.flock` and removes it with every other `.flock`.
- **A request already open** (`factory-reset.conf` is there, and no
  `factory-reset.keep`): replace it the same way (it is then a new request), or
  remove it, with the `.flock`, to cancel. **A reset that has begun**
  (`factory-reset.keep` is there): change nothing; it goes on at the next
  start.
- **Then restart** (`systemctl reboot`). Nothing happens before the restart.
- **At the next start** the device resets and restarts by itself, once, and
  comes up as a first boot: enrolled with the new `.flock` and reachable over
  SSH as its owner, or unenrolled and reachable on the console only. An attempt
  that fails does not restart the device: it comes up as it is (`result=failed`)
  and tries again at its next start, which nobody but a person or an update
  brings about. Two restarts for a reset that works; up to an hour on a disk
  that does not answer.
- **The state.** `/var/lib/flockos/factory-reset.state` of the booted slot, for
  a status: `request=`, `attempts=` (made so far), `erase=` (`no` or `started`),
  `outcome=` (empty while open, `done` or `gave-up`), `last-failure=`. Read only.
  An update carries it into the new slot. The data partition holds
  `flockos/factory-reset.done` with `request=` and `outcome=` of the last
  request that ended there.
- **The record.** `/boot/efi/factory-reset.log`, replaced by every attempt, the
  give-up and every refusal, and the same in the booted slot as
  `/var/lib/flockos/factory-reset.log` (for when the FLOCKOS partition cannot be
  written; take the newer by `time`). `KEY=value` lines after a comment line.
  None is written when the reset waits for a start that is not a trial, when
  the script runs while `/data` is mounted, or when a request done before is
  found again (unless its record was lost: it is then written anew from the
  mark the reset left on `/data`).

  | Key | Value |
  |-----|-------|
  | `result` | `done`; `incomplete` (done, some steps failed); `failed` (this attempt, tried again at the next start); `gave-up`; `refused` |
  | `time` | when it was written, UTC, by the device's clock (`2026-11-10T18:00:00Z`) |
  | `image`, `version` | `IMAGE_ID` and `IMAGE_VERSION` of the system that ran it |
  | `slot` | the booted slot, `A`, `B` or `unknown` |
  | `request` | the request's identity (checksum, size, time of change), as in the state |
  | `attempt`, `attempts-max` | all but `refused`: the attempt this is, of `3` |
  | `keep-network` | `done`, `incomplete`, `gave-up`: `yes` or `no` as the request said; `unknown` when it could not be read back from `factory-reset.keep` |
  | `kept` | `done`, `incomplete`: what was kept, of `rauc network/connections flockos/proxy.conf flockos/ptp.conf`, space-separated |
  | `other-slot` | `done`, `incomplete`: `cleaned`, `none (...)` (no partition or filesystem), or `not cleaned (...)`: on another disk, no IronFlockOS, the booted slot is none of `system.conf`, cannot mount, error |
  | `note` | `done`, `incomplete`, when something could not be kept: why |
  | `failed-steps` | `incomplete`: the steps that failed, space-separated, of `restore`, `booted-slot`, `other-slot`, `grubenv`, `keep-file` |
  | `reason` | `failed`, `gave-up` (the last failure), `refused`: why; for `refused` one of the reasons of `check`; for `failed` also `cannot count the attempt in <file>` (no attempt was made) and `the attempt did not end within <n> seconds` |
  | `begun` | `failed`: whether `factory-reset.keep` had its name |
  | `data` | `failed`, `gave-up`: what `/data` holds now: `old` (not erased), `new` (a new filesystem, with the kept files), `none` (no filesystem mounts: the device runs without `/data`) |
  | `left` | `gave-up`: what of the old owner may still be on the device, space-separated, of `data`, `booted-slot`, `other-slot`; empty when nothing is |

  It names nothing of the old owner.

## The nvidia variant

`nvidia` is `base` plus NVIDIA's driver for containers on amd64 (WP-4.1;
master plan, section 3.7), in 8 GiB slots, with the RAUC compatible
`flockos-amd64-efi-nvidia`. Everything comes at the versions pinned in
`profiles/nvidia/versions`:

- `nvidia-driver-cuda` and `firmware-nvidia-gsp` from NVIDIA's CUDA repository
  for Debian 13: CUDA and NVML libraries, `nvidia-smi`, `nvidia-persistenced`,
  headless (no X driver).
- NVIDIA's open kernel modules (Turing and newer). Inside the tree,
  `build/nvidia-modules.sh` installs the kernel headers and
  `nvidia-kernel-open-dkms`, lets DKMS build the modules for the image's
  kernel, wraps them in the package `flockos-nvidia-modules`, and purges DKMS,
  the sources, the headers and the compiler again. The build fails when the
  package set afterwards differs from the one before by anything but
  `flockos-nvidia-modules`.
- `nvidia-container-toolkit` from NVIDIA's libnvidia-container repository;
  `ironflock-init bake` sees `nvidia-container-runtime` and adds the `nvidia`
  runtime to Docker's `daemon.json`.

Both repositories stay in the image's apt sources with their keys embedded
(`profiles/nvidia/apt`). nouveau and nova-core are blacklisted, also in the
initramfs. Without a GPU nothing of NVIDIA's runs: `nvidia-persistenced` is
started by udev when the `nvidia` module loads, which happens only for an
NVIDIA GPU, and `10-flockos-nvidia.preset` keeps it and `nvidia-powerd` (a
notebook feature) from being enabled on a slot's first boot. No key the
machine trusts signs the modules, so a kernel booted with Secure Boot on refuses
them (ADR-0011): `flockos-nvidia-secure-boot`, started by udev for each NVIDIA
display controller, then says on the console that the GPU needs Secure Boot off.

## The installer variant

`just build amd64-efi installer` (or `arm64-efi installer`) builds the IronFlockOS
installer stick of that target (master plan, section 3.6). One stick per target
carries every image of it: the variants in `INSTALLER_PAYLOADS` of
`target.conf` (amd64-efi `base base-rt nvidia`, arm64-efi `base base-rt`),
built before it (`just build amd64-efi base`, `... base rt`, `... nvidia`);
`FLOCKOS_INSTALLER_PAYLOADS` overrides the list for a local build, for example
`FLOCKOS_INSTALLER_PAYLOADS=base just build amd64-efi installer`. The boot
entry it writes names the target's loader (`BOOTX64.EFI`, `BOOTAA64.EFI`). It
is the base system plus `profiles/installer` (the installer program,
`efibootmgr`, its own `fstab`), with each image embedded as
`/usr/share/flockos/payload/<image id>-<version>.img.zst` and its raw size next
to it, and `<image id>-<version>.payloads` next to the image in `out/`: the
image ids it carries, for the catalog's `payloads`. Its root slot is
`SLOT_SIZE_INSTALLER` (5 GiB on amd64-efi, 4 GiB on arm64-efi), sized for the
payloads; the build's slot-fill check holds it to them. It has no RAUC bundle,
no slot B, no `/data`, no SSH and no device services, and its GPT names differ
(`flockos-installer-esp`, `flockos-installer`), so a disk it installed and the
stick never collide; its FAT label is `FLOCKOS` as on every image, for
FlockFlasher.

On boot `flockos-installer.service` runs on the console: it reads
`installer.conf` and the `.flock` from the stick's FLOCKOS partition, picks the
image (`payload=`: an image id as FlockFlasher writes it, such as
`flockos-amd64-efi-nvidia`, or a variant, such as `base-rt`; it may be left out
only on a stick with one image), picks the target disk (`disk=largest`, `/dev/<name>` or `by-id:<id>`; never the stick,
read-only, loop or too small disks; USB disks only with `allow-usb=yes`), asks
unless `confirm=no`, writes the image, copies the `.flock` to the new FLOCKOS
partition, adds a UEFI boot entry, and powers off (`after=reboot` reboots). The
log is `flockos-installer.log` on the stick.

## The rt kernel

`just build amd64-efi base rt` builds the `-rt` image (master plan, section
3.11): Debian's PREEMPT_RT kernel (`linux-image-rt-amd64`; on arm64-efi
`linux-image-rt-arm64`) instead of the target's standard one, `rt-tests`
(`cyclictest`, `hwlatdetect`), and `flockos-rt-tuning`. Its RAUC compatible is
`flockos-<target>-base-rt`, so an `-rt` device only takes `-rt` bundles;
switching kernels is a reflash in 1.x. The rt kernel is offered for `base` on
the EFI targets only: NVIDIA's modules do not support PREEMPT_RT on x86, and
the Raspberry Pi boots its own kernels.

`/etc/flockos/rt.conf` (on `/data`, written by the platform) sets the tuning:

```ini
isolate=2-3      # CPUs for real-time work: isolcpus, nohz_full, rcu_nocbs
irq=0-1          # CPUs that take interrupts: irqaffinity
cstates=limit    # limit deep C-states (default); on: leave them
thp=never        # transparent huge pages (default never)
governor=performance
```

`flockos-rt-tuning` runs at boot and whenever the file changes. It writes the
kernel parameters into `FLOCKOS_RT_CMDLINE` in grubenv, which GRUB adds on both
slots, so they survive updates; a change applies at the next boot, and
`/run/flockos/rt-reboot-required` says so. THP and the governor apply at once.
Real-time containers run with `--cap-add SYS_NICE --ulimit rtprio=99
--cpuset-cpus <isolated CPUs>`.

## Building locally

Docker is the only requirement. On an arm64 Mac an amd64 image builds under
emulation, which is slow (about half an hour) but works:

```sh
just build amd64-efi base
```

The scratch space is a Docker volume (`flockos-work`) by default, because a
macOS bind mount cannot hold a Linux root filesystem; set `FLOCKOS_WORK` to a
directory on a native Linux filesystem instead where there is one (CI uses
`/mnt/flockos-work`). A build from a working tree with uncommitted changes gets
`-dirty` in its `BUILD_ID`. Local builds always sign with throwaway keys: such
an image installs only bundles from the same build.

## Reproducibility

`SOURCE_DATE_EPOCH` is the commit time; file times, filesystem UUIDs, the ext4
hash seed and the FAT volume id are derived from it or from the image id. The
distribution's archive is not pinned to a snapshot, so two builds of one commit
on different days can differ in package versions; `packages.tsv` records what
went in. Docker CE and its companions are pinned in `distros/<distro>/versions`,
the NVIDIA packages in `profiles/nvidia/versions`.

A pin moves for a security fix as soon as the fixed package is in the vendor's
signed repository and CI passes; there is no waiting period. Other updates go
in with the next sweep of the pins. A new major line, such as a new NVIDIA
driver branch, is weighed on its own: whether the vendor still supports the old
one, the hardware and APIs it adds or drops. Findings that no installable
release fixes yet are accepted in `.trivyignore.yaml`, with an expiry.
