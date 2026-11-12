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
| signing material | `build/signing.sh` | `keyring.pem` the image trusts, the signer certificate and key. Throwaway by default; a release build (`IRONFLOCKOS_SIGNING=release`) puts the IronFlockOS root CA into the image and seals the bundle with a throwaway key for `release.yml`'s sign job (ADR-0006, `docs/signing.md`) |
| rootfs | `build/mkrootfs.sh` | minbase tree of the target's distribution (see below) from `mmdebstrap` with `profiles/base/packages`, its per-distribution and per-architecture lists, the target's `targets/<target>/packages` and the variant's `profiles/<variant>/packages` (no Recommends), Docker CE from download.docker.com at the versions in `distros/<distro>/versions`; for `nvidia` also NVIDIA's driver, its open kernel modules and the container toolkit (see below) |
| customisation | `build/customize.sh` | `overlay/` copied in, RAUC `system.conf` and keyring, `repart.d`, os-release, no accounts but a locked root, kernel at `/vmlinuz`, units enabled and masked, IronFlock baked in (`build/bake.sh`; not into the installer), package manifest, timestamps clamped to the commit time |
| disk image | `build/mkimage.sh` (EFI targets), `build/mkimage-rpi.sh` (Raspberry Pi: IRONFLOCKOS with `autoboot.txt`, boot-a from `/boot/firmware`, an empty boot-b, slot A) | IRONFLOCKOS partition (ESP: shim, Debian's signed GRUB, `grub.cfg`, `grubenv`), slot A as ext4 of the full slot size, assembled by `genimage` from `targets/<target>/genimage.cfg`, compressed |
| bundle | `build/mkbundle.sh` | verity RAUC bundle of slot A's filesystem, `compatible=ironflockos-<target>-<variant>[-rt]`, signed and verified against the image keyring (none for the installer); on `rpi-arm64` with the boot partition as `boot.vfat` |

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
| `<image-id>-<version>.sizes` | `raw_size=` and `min_disk_size=` of the image, in bytes, for the release catalog ([below](#the-smallest-disk)); not published itself |
| `<image-id>-<version>.modules.alias.gz` | the hardware list: per kernel of the image, the `alias` lines of `modules.alias` and `modules.builtin.modinfo` and a `builtin <module>` line per driver of `modules.builtin`, which `ironflock os install` matches a machine against ([release.md](release.md#what-ironflock-os-install-reads)); not for Jetson, which has no disk image |
| `SHA256SUMS` | checksums of the image and the bundle |

## Disk layout on a device

The image holds the IRONFLOCKOS partition and slot A only. On the first boot
`systemd-repart` (definitions in `targets/<target>/repart.d/`) creates slot B
with the same size and the `data` partition over the rest of the disk, and
formats `data`. `/etc/fstab` mounts `data` at `/data` and bind-mounts the
persistent paths from it (master plan, section 3.2). No mount there can stop
the boot (`nofail`, each still ordered before `local-fs.target`): a device
whose `/data` cannot be mounted runs on the root slot's own folders, without
Docker, and `ironflockos-data-missing` says so on the console and in
`/run/ironflockos/data-missing` (ADR-0015).

`/data` and the IRONFLOCKOS partition are checked before they are mounted
(`systemd-fsck`, the last field of their lines in `/etc/fstab`), and
`fsck.repair=yes` on the kernel command line of every target (ADR-0020) has the
check repair what it finds. Without it the check only preens, and a `/data` with
damage a preen gives up on, as a power cut can leave it, would stay unmounted
with nobody there to run `fsck` by hand. A repair can drop damaged files. The
check is not forced at every boot: it runs when the filesystem is marked as not
clean or as having errors. The root slot is mounted by the initramfs, where
ext4 replays its journal; a slot that does not boot falls back to the other one
("Boot and A/B"). On the EFI targets the command line is in `grub.cfg` on the
IRONFLOCKOS partition, which an update does not write, so a device installed
before this keeps the preen.

| Path | From |
|------|------|
| `/opt/ironflock` | `/data/ironflock` (agent, `.flock` copy, Docker data-root) |
| `/home` | `/data/home` |
| `/etc/NetworkManager/system-connections` | `/data/network/connections` |
| `/var/log` | `/data/log` (the journal and every other log: logs never fill the fixed-size root slot) |
| `/var/cache/ironflockos` | `/data/cache` (downloaded bundles) |
| `/var/lib/fwupd` | `/data/fwupd` |
| `/var/lib/systemd/pstore` | `/data/pstore` (what the kernel recorded about a crash, kept across updates) |
| `/apps` | `/data/apps` (the apps' data: the device-agent's `-appsDir`, each app's `/data` and `/shared`; `nofail`, see below) |

`/apps` is mounted `nofail`: a mount that fails does not stop the boot, as
the device-agent is the device's lifeline. Docker, the agent and enroll are
ordered after the mount in `/etc/fstab` itself (`x-systemd.before=`), as
`nofail` drops its order before `local-fs.target`, so none of them writes
under `/apps` before it is there. When it failed, they start all the same on
the slot's own `/apps`, and `ironflockos-apps-check`, between the mount and them,
says on the console and in the journal that the apps' data is lost at the
next update, leaves `/run/ironflockos/apps-not-persistent`, and fails.

Up to 0.14.0 `/apps` was part of the root slot, and every update started the
apps with empty data. The update into 0.15.0 does so one last time: its slot
mounts the empty `/data/apps`, and the apps' data of before stays in the
other slot's `/apps`. There is no migration: copying it at that boot would be
a long step at the worst moment, and no device in the field runs IronFlockOS
yet.

SSH host keys are made on the first boot in `/data/etc/ssh` and `sshd` is
pointed there. The machine-id is generated on the first boot in the slot; RAUC's
post-install handler (`/usr/lib/ironflockos/rauc-post-install`) copies it and the
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
(`IRONFLOCKOS_SLOT_FILL_WARN`, `IRONFLOCKOS_SLOT_FILL_MAX`). v0.10.0's trees fill about a
third of their slots (1.2 to 1.4 GiB of 4 GiB, 2.1 GiB of nvidia's 8 GiB).
Outgrowing a slot takes a new image id with a larger slot, not a bundle.

### The smallest disk

An image becomes a working device on a disk that holds its whole layout:
every partition of `repart.d` at its `SizeMinBytes` (the IRONFLOCKOS partition,
on the Raspberry Pi both boot partitions, both slots), `/data` at 1 GiB, and
2 MiB for the GPT (1 MiB in front of the first partition, 1 MiB at the end for
the backup GPT and the alignment). The image stage computes it from the
rendered `repart.d` (`min_disk_size` in `build/lib.sh`) and writes it with the
image's raw size to `<image-id>-<version>.sizes`; the release catalog names
both ([release.md](release.md#what-ironflock-os-install-reads)). The
installer makes no partitions: its smallest disk is its raw size.

| Image | Smallest disk |
|-------|---------------|
| `amd64-efi base`, `arm64-efi base`, both `-rt` | 9,934,209,024 bytes (9.25 GiB + 2 MiB) |
| `amd64-efi nvidia` | 18,524,143,616 bytes (17.25 GiB + 2 MiB) |
| `rpi-arm64 base` | 10,269,753,344 bytes (9.5625 GiB + 2 MiB) |

The raw image of `base` holds the IRONFLOCKOS partition and slot A: 4,564,471,808
bytes in 0.14.0. The Compute Engine images of a release have the smallest
disk rounded up to whole GiB, 10 GiB and 18 GiB for nvidia ([release.md](release.md),
"The VM images"), the numbers ADR-0008 of IronFlock/ironflock-cli gives.

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
That first mark proves the slot: `ironflockos-slot-proven` leaves a file in the
slot's own root filesystem, which an update replaces. A slot with that file is
marked good again once it has stayed up for two minutes after reaching
`multi-user.target` (`ironflockos-slot-keep.timer`), so a restart without a
connection does not move the device to its other slot, and a slot that fails
within those two minutes still falls back. A device that never
reaches the platform keeps booting its good slot: when every slot has been
tried, GRUB starts over with the first good one.

`IRONFLOCKOS_CMDLINE` in `grubenv` appends kernel parameters on both slots, for
diagnosis in the field (`grub-editenv /boot/efi/EFI/BOOT/grubenv set
IRONFLOCKOS_CMDLINE=...`) and for the QEMU tests. `IRONFLOCKOS_BOOT=text`
boots without the splash, and `splash.cpio` next to `grubenv` is the device's
own splash picture ([The screen](#the-screen)).

Known limit of 1.x: slots are found by GPT partition name (`rootfs-a`,
`rootfs-b`, `data`) and every image of a target has the same partition UUIDs.
A second IronFlockOS disk attached to a running device is therefore ambiguous; the
installer USB uses its own names.

## IronFlock in the image

`build/bake.sh` fetches `ironflock`, the IronFlock command of IronFlock/ironflock-cli,
at the version pinned in `profiles/base/versions` (`IRONFLOCK_VERSION`), from
`cli/linux/<arch>/<version>/ironflock` below the download base, checks its OpenPGP
signature (`.asc`) against the IronFlock bootstrap key (`profiles/base/keys`, pinned
by SHA-256) as the CLI's `install.sh` does, and runs `ironflock bake` on the tree:
the verified agent of the production channel, Docker's `daemon.json`, the
NetworkManager and dbus restart drop-ins, the login banner, and `ironflock` itself as
`/usr/bin/ironflock`. The build fails unless `/usr/bin/ironflock` is the verified
download and `/usr/lib/ironflock/image.json` names the pinned version as
`ironflock_version`; that record, with the agent version, goes into
`<image-id>-<version>.ironflock.json`.

On the device `ironflockos-enroll.service` runs `ironflock enroll` on the first
boot of every slot and whenever a `.flock` lies on the IRONFLOCKOS partition: with
the newest `.flock` there (removed afterwards, and every other `.flock` there
with it, as each would enroll the device again), else with the agent's own copy
on `/data`. The name's case does not count (`Device.FLOCK` is a `.flock`), as for
`ironflock`. A `.flock` that `ironflock enroll` does not accept (exit code 4: not
readable, not JSON, no `device_key` or `secret`; nothing changed) is renamed to
`<name>.rejected` on the partition, where it is kept and enrolls nothing, and the
next one is taken: the next newest, at last the agent's copy. Each is tried once
per boot: the device comes online with what there is, and nothing loops. When a
step after the agent's fails (exit code 1), the agent runs all the same; the
`.flock` it took has left the partition, so the other ones go too. A slot that did
not enroll stays unmarked, and the next boot tries again (a `.rejected` file is not
taken again). While a factory reset may still find the old owner's data on
`/data`, a `.flock` there waits; once it has begun to erase, or without
`/data`, enroll takes it and leaves it there ("Factory reset"). An A/B update
brings a slot without the SSH user and the agent's unit; enroll puts them back without network. Enroll also sets the hostname
from the device name in the `.flock` (ADR-0009), made into a valid hostname by
`ironflock`. A device keeps its hostname with `hostname-from-flock=no` in
`/etc/ironflockos/enroll.conf`, which links to `/data/ironflockos/enroll.conf` and so
outlives updates.

`ironflock` on the device is the same command as elsewhere, with what fits an
IronFlockOS device: `ironflock status` shows the system, its slots and the agent;
`ironflock agent configure -c <file>` enrolls the device with another `.flock` the
way the image does (it becomes the agent's copy); `agent install`, `agent remove`
and the proxy flags of `agent configure` refuse (exit code 3), as the image brings
the agent and keeps its proxy in `/etc/ironflockos/proxy.conf`.

The device-agent marks the booted slot good once it has reached the platform
(WP-2.4, device-agent 1.6.0); a slot it never marks falls back.

## Time

chrony keeps the clock on every image ([ADR-0013](adr/0013-chrony-keeps-the-time-ptp-per-device.md)).
It uses the distribution's NTP pools and the NTP servers DHCP hands out
(NetworkManager passes them to chrony).
`chronyd -s` (`/etc/default/chrony`) starts the clock from the real-time clock or,
on a board without one, at the time chronyd last stopped, as systemd-timesyncd
did with its clock file. `chronyc tracking` and `chronyc sources` show the state.

PTP is a device setting. `/etc/ironflockos/ptp.conf` links to
`/data/ironflockos/ptp.conf`, so it outlives updates:

```ini
interface=enp88s0   # the interface for PTP; without it PTP is off
role=client         # client (default) or server, see below
domain=0            # 0 to 255
transport=udp4      # udp4, udp6 or l2
delay=e2e           # e2e or p2p
priority1=64        # role=server only: the priority it announces; lower wins
```

`ironflockos-ptp` reads it at boot, before chrony starts, and again whenever the
file changes (`ironflockos-ptp.path`): a change applies within seconds, without a
reboot. With an interface, `ironflockos-ptp4l` runs PTP on it and `ironflockos-phc2sys`
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
the journal of `ironflockos-ptp4l` says when it has none. `chronyc sources` lists
`#* PTP` while a client keeps PTP time; `journalctl -u ironflockos-ptp4l -u ironflockos-phc2sys`
and `pmc -u -b 0 -d <domain> 'GET CURRENT_DATA_SET' 'GET PARENT_DATA_SET'`
(`offsetFromMaster`; a server's own `clockIdentity` as `grandmasterIdentity`)
show the PTP side.

## Proxy

A site that reaches the internet only through a proxy sets it in
`/etc/ironflockos/proxy.conf`, which links to `/data/ironflockos/proxy.conf`, so it
outlives updates ([ADR-0014](adr/0014-proxy-per-device-from-the-ironflockos-partition.md)):

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
the file comes with the boot medium: a `proxy.conf` on the IRONFLOCKOS partition,
next to the `.flock` (FlockFlasher writes it), replaces the device's on the next
boot and is removed from the partition; during a factory reset it waits, or is
taken and left there, as the `.flock` is ("Factory reset"). The installer stick passes its
`proxy.conf` on to the disk it installs, and keeps it for the next device. On a
device that runs, editing `/etc/ironflockos/proxy.conf` applies within seconds.

`ironflockos-proxy` turns the file into `/run/ironflockos/proxy.env` at boot, before
containerd, Docker, the device-agent and chrony start, and again whenever the
file changes (`ironflockos-proxy.path`), restarting those that run. Drop-ins in the
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

## Network profiles

NetworkManager keeps a device's network profiles in
`/etc/NetworkManager/system-connections`, which is `/data/network/connections`,
so they outlive updates. A device on a network without DHCP, or on a Wi-Fi
network other than its `.flock`'s, needs its profile before it can reach the
platform, so the profile comes with the boot medium
([ADR-0016](adr/0016-network-profiles-from-the-ironflockos-partition.md)): a
NetworkManager keyfile on the IRONFLOCKOS partition, `network/<name>.nmconnection`,
becomes a profile of the device at the next boot and leaves the partition.
`ironflock os install` puts one there for a machine with a static address or a
Wi-Fi network; a person can put one there with the medium in another computer.

```ini
# network/office.nmconnection
[connection]
id=office
uuid=6f1b1f8e-4a52-4f3e-9d0b-5a1c2e3d4f50
type=ethernet

[ethernet]
mac-address=52:54:00:12:34:56

[ipv4]
method=manual
address1=192.168.10.20/24
gateway=192.168.10.1
dns=192.168.10.1;
```

`ironflockos-network-profiles` (`/usr/lib/ironflockos/network-profiles`) runs at every
boot where one lies there, the first included, after `/data` is mounted and
before NetworkManager starts. It writes each profile to
`/data/network/connections/<name>.nmconnection` with mode 0600, where it
replaces the device's profile of that name and any other with the same `uuid`,
then overwrites the file on the partition and removes it, one file after the
other. NetworkManager waits for it at most two minutes; what a run cut short
did not take is taken at the next boot. A file that is not a
keyfile NetworkManager can read (a name of other characters, over 64 KiB, no
`type=` in `[connection]`, ...) is renamed to `<name>.nmconnection.refused`, the
reason goes to the journal and the console, and the unit fails; the others are
taken. During a factory reset they follow `/run/ironflockos/factory-reset-hold` as the
`.flock` and `proxy.conf` do (after a reset that gave up they are taken as on
any device), and without `/data` they go to the root slot's own folder
(ADR-0016, section 8).
ADR-0016 has the rules and the contract for the caller;
`/usr/lib/ironflockos/network-profiles check FILE` tells whether a file would be
taken.

The profiles taken are on trial, as a profile NetworkManager reads can still
take a device off its network: the device's profiles they replaced are kept in
`/data/network/trial`, and `ironflockos-network-profiles-trial` keeps the taken
ones once the device-agent has connected with them. Without a connection
within 15 minutes of an enrolled device's uptime the earlier profiles come
back, and while the agent does not connect the two take turns, twice as long
each time, up to four hours (ADR-0016, section 10).

Enrollment writes the `.flock`'s Wi-Fi as `ironflock-wifi.nmconnection` after
NetworkManager has started.

## Factory reset

A factory reset returns a device to the state of a freshly flashed one that
waits for a `.flock` ([ADR-0015](adr/0015-factory-reset-requested-on-the-ironflockos-partition.md)).
It is requested by the file `factory-reset.conf` on the IRONFLOCKOS partition and
runs at the next boot, before `/data` is mounted:

```ini
keep-network=yes   # keep the network profiles, proxy.conf and ptp.conf (default no)
```

`ironflockos-factory-reset` (`/usr/lib/ironflockos/factory-reset`) copies what is kept
into `factory-reset.keep` on the IRONFLOCKOS partition, clears what the
enrollment, the agent, apps and users left in both root slots, makes a new
filesystem on the data partition, puts the kept files back, writes
`factory-reset.log`, removes the request and restarts. What is kept: RAUC's
state (`/data/rauc`) always; with `keep-network=yes` also
`/data/network/connections`, `/data/ironflockos/proxy.conf` and
`/data/ironflockos/ptp.conf`. Everything else on `/data` goes. In the root slots
the reset removes `/apps`, containerd's and NetworkManager's state, root's
files, the sudo rule and the agent's unit, `/var/lib/ironflockos/enrolled` and the
accounts the enrollment made, and sets the hostname back to `ironflockos` and the
machine-id to `uninitialized`; `slot-proven`, `ORDER` and the `_OK` flags of
`grubenv` stay. On the EFI targets it also takes `IRONFLOCKOS_RT_CMDLINE` and
`IRONFLOCKOS_BOOT` out of `grubenv` and removes the device's own splash,
`splash.cpio` and `splash.env` next to it
([The screen](#the-screen)). ADR-0015 lists every path. The boot after the reset is a first
boot: new machine-id and host keys, `/data` laid out anew, a `proxy.conf` and a
`.flock` on the IRONFLOCKOS partition taken in.

No failure of the reset keeps a device offline. Each request has three
attempts, counted in `/var/lib/ironflockos/factory-reset.state` of the booted slot
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
with the request are removed. `/run/ironflockos/factory-reset-hold` tells enroll
and `ironflockos-proxy` what to do with the IRONFLOCKOS partition's `.flock` and
`proxy.conf`: leave them (`wait`, a request is open and the old owner's data
may be on `/data`; `gave-up`, they could not be removed after a give-up), or
take them and leave them there (`copy`, once the erase has begun). Network
profiles there follow `wait` and `copy` the same way, and after a give-up they
are taken as on any device, on trial ([Network profiles](#network-profiles)).
A reset ends a trial of network profiles: with `keep-network=yes` the profiles
in use are kept, with `keep-network=no` none of the old ones comes back. A request the
device does not understand is refused, not counted, and renamed to
`factory-reset.conf.refused`. On a Raspberry Pi that runs an update on trial,
the reset waits for the next boot that is not a trial. The steps are on the
console and in the journal; `factory-reset.log` keeps the result.

### The contract for the CLI

`ironflock os reset [-c new.flock] [--keep-network]` (IronFlock/ironflock-cli) is written
from this section.

- **Support.** The device can reset when `/usr/lib/ironflockos/factory-reset`
  exists.
- **`check`.** `/usr/lib/ironflockos/factory-reset check FILE` changes nothing.
  - Exit 0: FILE is a request the device accepts. stdout is exactly one line,
    `keep-network=yes` or `keep-network=no`.
  - Exit 1: refused. stderr is one line, `factory-reset: <reason>`, without the
    file's name. The reasons: `the request is not a file`, `the request is
    larger than 4 KiB`, `the request holds a NUL byte`, `line <n> is not a
    key=value line`, `line <n>: keep-network must be yes or no`, `line <n>:
    keep-network is given twice, with different values`, `line <n>: unknown key
    <key>`.
  - Exit 2: wrong arguments.
- **The request.** `/boot/efi/factory-reset.conf`, on the IRONFLOCKOS partition of
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
  `factory-reset.conf.gave-up` (on a read-only IRONFLOCKOS partition, at the first
  boot it can be written), and both are marked on `/data` and in the state,
  which an update carries into the new slot. To try again, write a new
  request.
- **The hold.** `/run/ironflockos/factory-reset-hold`, written at each boot the
  reset runs: `wait` (a request is open; the IRONFLOCKOS partition's `.flock` and
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
- **The state.** `/var/lib/ironflockos/factory-reset.state` of the booted slot, for
  a status: `request=`, `attempts=` (made so far), `erase=` (`no` or `started`),
  `outcome=` (empty while open, `done` or `gave-up`), `last-failure=`. Read only.
  An update carries it into the new slot. The data partition holds
  `ironflockos/factory-reset.done` with `request=` and `outcome=` of the last
  request that ended there.
- **The record.** `/boot/efi/factory-reset.log`, replaced by every attempt, the
  give-up and every refusal, and the same in the booted slot as
  `/var/lib/ironflockos/factory-reset.log` (for when the IRONFLOCKOS partition cannot be
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
  | `request` | the request's identity (checksum, size, time of change), as in the state; for `refused` too, `unreadable-<time>` when its content cannot be read |
  | `attempt`, `attempts-max` | all but `refused`: the attempt this is, of `3`, never `0`; with `reason=cannot count the attempt in <file>` the attempt that was due and not made |
  | `keep-network` | `done`, `incomplete`, `gave-up`: `yes` or `no` as the request said; `unknown` when it could not be read back from `factory-reset.keep` |
  | `kept` | `done`, `incomplete`: what was kept, of `rauc network/connections ironflockos/proxy.conf ironflockos/ptp.conf`, space-separated |
  | `other-slot` | `done`, `incomplete`: `cleaned`, `none (...)` (no partition or filesystem), or `not cleaned (...)`: on another disk, no IronFlockOS, the booted slot is none of `system.conf`, cannot mount, error |
  | `note` | `done`, `incomplete`, when something could not be kept: why |
  | `failed-steps` | `incomplete`: the steps that failed, space-separated, of `restore`, `booted-slot`, `other-slot`, `grubenv`, `splash`, `keep-file` |
  | `reason` | `failed`, `gave-up` (the last failure), `refused`: why; for `refused` one of the reasons of `check`; for `failed` also `cannot count the attempt in <file>` (no attempt was made) and `the attempt did not end within <n> seconds` |
  | `begun` | `failed`: whether `factory-reset.keep` had its name |
  | `data` | `failed`, `gave-up`: what `/data` holds now: `old` (not erased), `new` (a new filesystem, with the kept files; when no attempt was made, one that mounts), `none` (no filesystem mounts: the device runs without `/data`) |
  | `left` | `gave-up`: what of the old owner may still be on the device, space-separated, of `data`, `booted-slot`, `other-slot`; empty when nothing is |

  It names nothing of the old owner.

## AppArmor

The Debian images carry AppArmor's tools (`apparmor` in
`profiles/base/packages.debian`; ADR-0020). Debian's kernels have AppArmor on,
and with the tools:

- Docker puts its `docker-default` profile on every container that is not
  privileged, as on any Debian or Ubuntu host: no mounts, no writes to the
  sensitive parts of `/proc` and `/sys`. A privileged container, and one
  started with `apparmor=unconfined`, gets no profile. `docker info` names
  `apparmor` among its security options.
- The profiles that Debian's packages bring are in force. In the image that is
  chrony's (`/etc/apparmor.d/usr.sbin.chronyd`). It does not allow the two
  folders the image has chronyd read below `/run/ironflockos` (the PTP source
  of "Time", the NTP servers of "Proxy"), so the image adds them in
  `/etc/apparmor.d/local/usr.sbin.chronyd`, which that profile includes. A new
  folder in `overlay/etc/chrony/conf.d` needs its line there; a unit test
  compares the two.

IronFlockOS brings no profiles of its own. `aa-status` shows what is loaded and
which processes are confined; a denial is in the journal
(`journalctl -k -g apparmor`). On the Raspberry Pi the kernel is Raspberry Pi's
and decides whether AppArmor is on; with it off the package does nothing. The
Jetson image (Ubuntu, NVIDIA's kernel) does not carry the package yet.

## The screen

A device with a screen shows a splash while it starts and keeps it on the
screen until an app draws ([kiosk-plan.md](kiosk-plan.md) has the plan and
the contract with a screen app). The EFI targets have it (`amd64-efi`,
`arm64-efi`); the Raspberry Pi and Jetson boot on text as before.

**Plymouth.** `plymouth`, its label plugin and fontconfig with DejaVu are
packages of the EFI targets. Its theme `ironflockos`
(`overlay/usr/share/plymouth/themes/ironflockos`, named in
`/etc/plymouth/plymouthd.conf`) draws one picture centred at its own size in
pixels on a background colour, never larger, made smaller only to fit a
smaller screen, with no spinner and no progress; below it, one line for a
message. The default picture is `docs/assets/ironflock-splash.png`,
`docs/assets/ironflock-white.svg` rendered at 320x320 pixels, transparent
around the logo (`rsvg-convert -w 320 -h 320` of Debian 13's librsvg 2.60, with
its `bKGD` chunk dropped, so that it is a PNG the image itself would take); in
the image it is the theme's `ironflock.png`. Animations are part of the theme:
`fade` (the default) fades the picture in over a second while the system
starts, `none` shows it at once; at shutdown it is shown at once. Plymouth's
initramfs hook puts Plymouth, the theme, the fonts and the kernel's graphics
drivers into the initramfs: `build/mkrootfs.sh` puts the theme into the tree
before it makes the initramfs again, and the build log names the initramfs's
size.

**The kernel command line.** `grub.cfg` boots with the splash unless
`IRONFLOCKOS_BOOT=text` is in `grubenv`, or `ironflockos.boot=text` in
`IRONFLOCKOS_CMDLINE`:

| | splash (default) | text |
|---|---|---|
| kernel parameters | `quiet splash plymouth.ignore-serial-consoles plymouth.force-frame-buffer-on-boot vt.global_cursor_default=0 fbcon=map:9` | `plymouth.enable=0` |
| GRUB | graphics mode, the splash's colour, kept for the kernel | the console, as before |
| GRUB's menu | hidden; Esc during its two seconds shows it | shown, as before |
| `/initrd.img` | and `splash.cpio`, when there is one | alone |
| tty1 | the splash, then a screen app; no login prompt | the boot messages and a login prompt |

`quiet` holds for the serial console too: the kernel has one log level for
all consoles. Errors still go there, and the journal keeps every line.
Plymouth draws nothing while a serial console is named unless told to ignore
it. Plymouth draws through the graphics device (DRM) once its driver is
there, and with `plymouth.force-frame-buffer-on-boot` also into the kernel's
framebuffer device, which it takes once `DeviceTimeout` in `plymouthd.conf`
has passed: a tenth of a second here, not Debian's eight (plymouthd asserts
a timeout above 0 and aborts on 0).
What it shows through the graphics device would go with it: the kernel
removes a framebuffer when the program that made it ends, turns the screen
off and shows the framebuffer device instead, black unless Plymouth drew into
it too. So at the end of the boot `plymouth-quit.service` runs
`/usr/lib/ironflockos/keep-splash`: Plymouth lets go of the screen
(`plymouth deactivate`), the framebuffer device, which holds the same picture,
is put on the screen in the same mode (a forced `FBIOPUT_VSCREENINFO`: no mode
change, only the other picture), the first virtual terminal is handed back
as Plymouth leaves it when it quits without letting go first, and then
Plymouth quits keeping its splash (`plymouth quit --retain-splash`). That
terminal stays in graphics mode, so nothing the kernel writes is drawn over
it; its keyboard is on (`K_UNICODE`; Plymouth turns it off while it reads
the keyboard itself, and the kernel then ignores Ctrl+Alt+F2 too); and it is
switched by a process (`VT_PROCESS`) that is gone, so that Ctrl+Alt+F2 finds
nobody to ask, resets it to text mode and switches.
`plymouth deactivate` alone leaves it in graphics mode switched by nobody
(`VT_AUTO`), where the kernel ignores every switch. keep-splash also writes
to the journal when Plymouth started. Nothing of the
image holds the graphics device after the boot; a screen app that opens it
takes the screen, and when it closes it, the picture is back. A Plymouth
that crashes leaves the device as it would be without a splash: a drop-in
for `plymouth-start.service` counts its crash signals as an ending, so the
system does not turn "degraded"; the journal keeps how it ended. With the
splash `getty@tty1` does not start (a drop-in with
`ConditionKernelCommandLine=!splash`); logind starts a login prompt on the
terminals 2 to 6 when one is switched to.

**The display setting.** `/etc/ironflockos/display.conf`, which links to
`/data/ironflockos/display.conf`:

```ini
boot=text   # splash (default) or text
```

`ironflockos-display` (`/usr/lib/ironflockos/display`) writes it into `grubenv`
as `IRONFLOCKOS_BOOT=text`, or takes `IRONFLOCKOS_BOOT` out for `splash`, at
every boot and whenever the file changes (`ironflockos-display.path`). GRUB
reads it on both slots, so it holds across updates; a change applies at the
next boot. A file with another key or value is refused: `grubenv` stays as it
is, the journal says why, the unit fails. The installer stick's `grubenv` has
`IRONFLOCKOS_BOOT=text`; the QEMU tests set `ironflockos.boot=text` in
`IRONFLOCKOS_CMDLINE`, except for the boots that test the splash.

**The device's own picture.** A screen app, such as IronFlock's kiosk app,
hands the device its splash in `/data/ironflockos/screen`, which
`ironflockos-data-layout` makes at every boot, before Docker, owned by root:

- `splash.png`: a PNG of at most 4 MiB and 3840x2160 pixels, with the chunks
  `IHDR`, `PLTE`, `tRNS`, `IDAT` and `IEND` and no others;
- `splash.conf`: `background=#RRGGBB` (default `#000000`) and
  `animation=none|fade` (default `fade`); `#` starts a comment at the start of
  a line or after a space.

The app writes each under another name in that folder, syncs it and renames
it. `ironflockos-splash` (`/usr/lib/ironflockos/splash`) takes them at every
boot and whenever one of the two names changes (`ironflockos-splash.path`; a
run that another name started reads the two names and changes nothing). It
checks them, refuses what the list above does not allow (the journal says
why, the unit fails, and the splash stays as it was), and packs the picture
and the theme's settings into a cpio archive, written under another name and
renamed to `splash.cpio` next to `grubenv`. GRUB loads it after the slot's
`initrd.img`, so the kernel unpacks it over the initramfs's theme and Plymouth
has the picture from the start: no initramfs is made on a device, and the
archive outlives updates. The archive holds the picture as the theme's
`splash.png` and the theme's script with the settings in its first lines;
an update that brings a new theme script gets a new archive at its first boot,
which applies from the boot after. A damaged archive stops no boot: the kernel
unpacks what it can and says `Initramfs unpacking failed` in its log, and the
theme shows IronFlock's logo when `splash.png` is missing or does not load.
Without either file the archive goes, and IronFlock's logo is back from the
next boot on. Plymouth at shutdown draws from the running system's theme:
`ironflockos-splash` mounts a copy of it with the archive's files from
`/run/ironflockos/splash-theme` over the theme's folder. A factory reset
removes the archive and `IRONFLOCKOS_BOOT` with the old owner's data
([Factory reset](#factory-reset)). `/usr/lib/ironflockos/splash check-png FILE`
and `check-conf FILE` tell whether a file would be taken.

**From the firmware's picture to the splash.** With the splash GRUB fills the
screen with the splash's background colour, in graphics mode (`gfxterm`,
with the font of Debian's GRUB for the menu), and the kernel keeps that mode
and what GRUB drew (`gfxpayload=keep`). `splash.env` next to `grubenv` names
the colour (`IRONFLOCKOS_SPLASH_BACKGROUND`, black from the build; GRUB reads
only this from it); `ironflockos-splash` writes it with every `splash.conf`
it takes. `gfxterm` fills its whole screen with the colour (the frames of the
QEMU test show no border); its text has a black, that is transparent,
background (`color_normal`, `color_highlight`), so what GRUB clears the
screen to stays the colour, and a `clear` right after draws it at once, for
the whole of the hidden menu's timeout (`gfxterm` draws a new background only
with its next output). The menu (Esc) shows its chosen entry inverted, in
its own colours (`menu_color_normal`, `menu_color_highlight`). GRUB draws no
picture: the picture comes with Plymouth, on the same colour. The kernel's
console stays off the screen while it starts (`fbcon=map:9`, a framebuffer
that never comes), so it does not clear the colour GRUB left before Plymouth
draws; once the running system finds a framebuffer, udev runs
`/usr/lib/ironflockos/consoles` (`71-ironflockos-consoles.rules`), which
gives the terminals their console back. By then Plymouth holds the first
terminal in graphics mode, where the console draws nothing; the terminals 2
to 6 have their text, and Esc shows the boot messages. In the initramfs, before
that, Esc shows nothing, and a failure there is on the serial console only;
"Start with messages" in the boot menu shows it on the screen.

Whether the colour stays when the kernel's graphics driver takes the screen
from the firmware's framebuffer is the driver's: Intel's keeps the mode and
its content; QEMU's (`bochs`, `virtio-gpu`) set their own mode and start with
an empty screen until Plymouth draws, which the QEMU test counts and does not
fail on (QEMU's standard VGA also shows one frame of the screen before read
with 24 bits a pixel while `bochs` sets its mode). The machine has the last
word (WP-8.6). GRUB drawing the picture as well is a later work package
(docs/kiosk-plan.md, WP-8.8): in QEMU GRUB put a picture at the screen's
corner, the same pixels as Plymouth's otherwise, and it needs a picture of
the whole screen taken after a boot, which only the panel can prove.

**Messages on the splash.** What the image says on the console to a person at
the device also goes to the line below the picture, through
`/usr/lib/ironflockos/screen-message TEXT` (`plymouth display-message` while
Plymouth runs; without Plymouth, as with `boot=text`, it does nothing and the
console lines are as they were):

| Script | Message |
|--------|---------|
| `ironflockos-enroll`, no `.flock` | Not enrolled: put this device's .flock file on its IRONFLOCKOS partition. |
| `ironflockos-enroll`, none accepted | Not enrolled: the .flock file on the IRONFLOCKOS partition was not accepted. |
| `ironflockos-data-missing` | The data partition could not be mounted: the apps do not run. |
| `ironflockos-apps-check` | The apps' data is not on the data partition: it is lost at the next update. |
| `ironflockos-network-profiles` | The network profile NAME was refused: it is not taken. |
| `ironflockos-factory-reset` | Factory reset: this takes a few minutes. Do not turn the device off. / Factory reset done: the device restarts. / The factory reset failed this time: the next start tries again. / The factory reset gave up: see factory-reset.log on the IRONFLOCKOS partition. |
| `ironflockos-nvidia-secure-boot` | Secure Boot is on: the NVIDIA GPU cannot be used. Turn Secure Boot off in the firmware setup. |

The theme shows the last one, in white on a dark background and in black on a
light one. Plymouth quits after `ironflockos-enroll` (the drop-in for
`plymouth-quit.service`), so the message that is there then stays below the
picture after the boot.

**Keys at the screen.** A person with a keyboard at the device has the keys
of any PC:

| Key | When | What |
|-----|------|------|
| the firmware's setup key | power-on | the firmware's setup, as the PC's maker set it |
| Esc | GRUB's two seconds | the boot menu: the slot GRUB chose, the other slot as its fallback (once it has been marked good), "Start with messages" (this boot on text, `boot=` stays as it is), "Firmware setup" (`fwsetup`; also for the `-rt` images, whose kernel turns the EFI runtime services off) |
| Esc | while Plymouth shows the splash | the boot messages; Esc again, the splash |
| Ctrl+Alt+F2 to F6 | after the boot | a login prompt (logind starts it on the first switch) |
| Ctrl+Alt+F1 | | back to the first terminal: the splash or the screen app; without a screen app, what the other terminal left there |
| Ctrl+Alt+Del | | restart, as before |

**The console password.** Nobody logs in at the console unless the device
has a console password (D8 of [kiosk-plan.md](kiosk-plan.md)):
`/data/ironflockos/console-password`, owned by root with mode 0600, written by
the device-agent from Studio, one line with a crypt(3) hash, yescrypt (`$y$`)
or SHA-512 (`$6$`). `ironflockos-console-password`
(`/usr/lib/ironflockos/console-password`) makes it the password of the device's
enrolled user, the account `ironflock enroll` makes from the `.flock`'s owner
for SSH, with its sudo rule; it finds that user in `ironflock`'s record of the
enrollment, `/opt/ironflock/device-init/installed.json` (`.user.name`), which
`ironflock status --json` does not show, and takes it only as an account of a
person (uid 1000 to 59999) with the rule `/etc/sudoers.d/ironflock-<name>`. It
runs at every boot after `ironflockos-enroll`, which makes the user anew in a
slot an update brought, before the login prompts (a drop-in orders
`getty@.service` after it), and whenever the file changes
(`ironflockos-console-password.path`). Without the file the password is locked,
as enroll leaves it. Root and every other account are never touched; root
stays locked. A file of another owner or mode, of more than one line, or with
anything but one such hash is refused: the journal says why, the password is
locked, the unit fails. SSH stays key-only (`PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitRootLogin no`). A factory reset
removes the file with the rest of `/data`.

**What a keyboard can do.** GRUB's editor stays open in this release (D9): a
person at the boot menu can press `e` and change the kernel command line, and
so start a root shell. With Secure Boot off, a USB stick with any system does
the same. Whoever stands at the device with a keyboard gets root, as on any PC
that is not locked down; Secure Boot here is no tamper protection
(ADR-0011). A GRUB password, a firmware password and disk encryption are
hardening for later.

The splash comes with a new installation only: `grub.cfg` is on the
IRONFLOCKOS partition, which an update does not write. A device installed
with 0.16.0 or earlier keeps booting on text after an update to a release
with the splash; it gets `ironflockos-splash`, which writes an archive its
`grub.cfg` never loads.

## The nvidia variant

`nvidia` is `base` plus NVIDIA's driver for containers on amd64 (WP-4.1;
master plan, section 3.7), in 8 GiB slots, with the RAUC compatible
`ironflockos-amd64-efi-nvidia`. Everything comes at the versions pinned in
`profiles/nvidia/versions`:

- `nvidia-driver-cuda` and `firmware-nvidia-gsp` from NVIDIA's CUDA repository
  for Debian 13: CUDA and NVML libraries, `nvidia-smi`, `nvidia-persistenced`,
  headless (no X driver).
- NVIDIA's open kernel modules (Turing and newer). Inside the tree,
  `build/nvidia-modules.sh` installs the kernel headers and
  `nvidia-kernel-open-dkms`, lets DKMS build the modules for the image's
  kernel, wraps them in the package `ironflockos-nvidia-modules`, and purges DKMS,
  the sources, the headers and the compiler again. The build fails when the
  package set afterwards differs from the one before by anything but
  `ironflockos-nvidia-modules`.
- `nvidia-container-toolkit` from NVIDIA's libnvidia-container repository;
  `ironflock bake` sees `nvidia-container-runtime` and adds the `nvidia`
  runtime to Docker's `daemon.json`.

Both repositories stay in the image's apt sources with their keys embedded
(`profiles/nvidia/apt`). nouveau and nova-core are blacklisted, also in the
initramfs. Without a GPU nothing of NVIDIA's runs: `nvidia-persistenced` is
started by udev when the `nvidia` module loads, which happens only for an
NVIDIA GPU, and `10-ironflockos-nvidia.preset` keeps it and `nvidia-powerd` (a
notebook feature) from being enabled on a slot's first boot. No key the
machine trusts signs the modules, so a kernel booted with Secure Boot on refuses
them (ADR-0011): `ironflockos-nvidia-secure-boot`, started by udev for each NVIDIA
display controller, then says on the console that the GPU needs Secure Boot off.

## The installer variant

`just build amd64-efi installer` (or `arm64-efi installer`) builds the IronFlockOS
installer stick of that target (master plan, section 3.6). One stick per target
carries every image of it: the variants in `INSTALLER_PAYLOADS` of
`target.conf` (amd64-efi `base base-rt nvidia`, arm64-efi `base base-rt`),
built before it (`just build amd64-efi base`, `... base rt`, `... nvidia`);
`IRONFLOCKOS_INSTALLER_PAYLOADS` overrides the list for a local build, for example
`IRONFLOCKOS_INSTALLER_PAYLOADS=base just build amd64-efi installer`. The boot
entry it writes names the target's loader (`BOOTX64.EFI`, `BOOTAA64.EFI`). It
is the base system plus `profiles/installer` (the installer program,
`efibootmgr`, its own `fstab`), with each image embedded as
`/usr/share/ironflockos/payload/<image id>-<version>.img.zst` and its raw size next
to it, and `<image id>-<version>.payloads` next to the image in `out/`: the
image ids it carries, for the catalog's `payloads`. Its root slot is
`SLOT_SIZE_INSTALLER` (5 GiB on amd64-efi, 4 GiB on arm64-efi), sized for the
payloads; the build's slot-fill check holds it to them. It has no RAUC bundle,
no slot B, no `/data`, no SSH and no device services, and its GPT names differ
(`ironflockos-installer-esp`, `ironflockos-installer`), so a disk it installed and the
stick never collide; its FAT label is `IRONFLOCKOS` as on every image, for
FlockFlasher.

On boot `ironflockos-installer.service` runs on the console: it reads
`installer.conf` and the `.flock` from the stick's IRONFLOCKOS partition, picks the
image (`payload=`: an image id as FlockFlasher writes it, such as
`ironflockos-amd64-efi-nvidia`, or a variant, such as `base-rt`; it may be left out
only on a stick with one image), picks the target disk (`disk=largest`, `/dev/<name>` or `by-id:<id>`; never the stick,
read-only, loop or too small disks; USB disks only with `allow-usb=yes`), asks
unless `confirm=no`, writes the image, copies the `.flock` to the new IRONFLOCKOS
partition, adds a UEFI boot entry, and powers off (`after=reboot` reboots). The
log is `ironflockos-installer.log` on the stick.

## The rt kernel

`just build amd64-efi base rt` builds the `-rt` image (master plan, section
3.11): Debian's PREEMPT_RT kernel (`linux-image-rt-amd64`; on arm64-efi
`linux-image-rt-arm64`) instead of the target's standard one, `rt-tests`
(`cyclictest`, `hwlatdetect`), and `ironflockos-rt-tuning`. Its RAUC compatible is
`ironflockos-<target>-base-rt`, so an `-rt` device only takes `-rt` bundles;
switching kernels is a reflash in 1.x. The rt kernel is offered for `base` on
the EFI targets only: NVIDIA's modules do not support PREEMPT_RT on x86, and
the Raspberry Pi boots its own kernels.

`/etc/ironflockos/rt.conf` (on `/data`, written by the platform) sets the tuning:

```ini
isolate=2-3      # CPUs for real-time work: isolcpus, nohz_full, rcu_nocbs
irq=0-1          # CPUs that take interrupts: irqaffinity
cstates=limit    # limit deep C-states (default); on: leave them
thp=never        # transparent huge pages (default never)
governor=performance
```

`ironflockos-rt-tuning` runs at boot and whenever the file changes. It writes the
kernel parameters into `IRONFLOCKOS_RT_CMDLINE` in grubenv, which GRUB adds on both
slots, so they survive updates; a change applies at the next boot, and
`/run/ironflockos/rt-reboot-required` says so. THP and the governor apply at once.
Real-time containers run with `--cap-add SYS_NICE --ulimit rtprio=99
--cpuset-cpus <isolated CPUs>`.

## Building locally

Docker is the only requirement. On an arm64 Mac an amd64 image builds under
emulation, which is slow (about half an hour) but works:

```sh
just build amd64-efi base
```

The scratch space is a Docker volume (`ironflockos-work`) by default, because a
macOS bind mount cannot hold a Linux root filesystem; set `IRONFLOCKOS_WORK` to a
directory on a native Linux filesystem instead where there is one (CI uses
`/mnt/ironflockos-work`). A build from a working tree with uncommitted changes gets
`-dirty` in its `BUILD_ID`. The commit in `BUILD_ID` is `HEAD`; on a pull
request CI names the pull request's head instead, when it has the same tree
(`IRONFLOCKOS_BUILD_COMMIT`, `build_commit` in `build/lib.sh`): `HEAD` there is
GitHub's test merge, which GitHub drops, and a release may reuse those images
([ADR-0018](adr/0018-the-release-reuses-the-dry-runs-images.md)). Local builds always sign with throwaway keys: such
an image installs only bundles from the same build.

## Reproducibility

`SOURCE_DATE_EPOCH` is the time of the commit the image names; file times, filesystem UUIDs, the ext4
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
