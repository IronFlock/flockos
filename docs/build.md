# Building FlockOS images

Every FlockOS image is built by `just build TARGET VARIANT [KERNEL]` inside a
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
| signing material | `build/signing.sh` | `keyring.pem` the image trusts, the signer certificate and key. Throwaway by default; a release build (`FLOCKOS_SIGNING=release`) puts the FlockOS root CA into the image and seals the bundle with a throwaway key for `release.yml`'s sign job (ADR-0006, `docs/signing.md`) |
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
| `<image-id>-<version>.os-release` | the image's `/etc/os-release` |
| `SHA256SUMS` | checksums of the image and the bundle |

## Disk layout on a device

The image holds the FLOCKOS partition and slot A only. On the first boot
`systemd-repart` (definitions in `targets/<target>/repart.d/`) creates slot B
with the same size and the `data` partition over the rest of the disk, and
formats `data`. `/etc/fstab` mounts `data` at `/data` and bind-mounts the
persistent paths from it (master plan, section 3.2):

| Path | From |
|------|------|
| `/opt/ironflock` | `/data/ironflock` (agent, `.flock` copy, Docker data-root) |
| `/home` | `/data/home` |
| `/etc/NetworkManager/system-connections` | `/data/network/connections` |
| `/var/log` | `/data/log` (the journal and every other log: logs never fill the fixed-size root slot) |
| `/var/cache/flockos` | `/data/cache` (downloaded bundles) |
| `/var/lib/fwupd` | `/data/fwupd` |

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
(device-agent 1.6.0); nothing in the image does it at boot. A device that never
reaches the platform keeps booting its good slot: when every slot has been
tried, GRUB starts over with the first good one.

`FLOCKOS_CMDLINE` in `grubenv` appends kernel parameters on both slots, for
diagnosis in the field (`grub-editenv /boot/efi/EFI/BOOT/grubenv set
FLOCKOS_CMDLINE=...`) and for the QEMU tests.

Known limit of 1.x: slots are found by GPT partition name (`rootfs-a`,
`rootfs-b`, `data`) and every image of a target has the same partition UUIDs.
A second FlockOS disk attached to a running device is therefore ambiguous; the
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
the newest `.flock` there (removed afterwards), else with the agent's own copy
on `/data`. An A/B update brings a slot without the SSH user and the agent's
unit; enroll puts them back without network. Enroll also sets the hostname
from the device name in the `.flock` (ADR-0009), made into a valid hostname by
`ironflock-init`. A device keeps its hostname with `hostname-from-flock=no` in
`/etc/flockos/enroll.conf`, which links to `/data/flockos/enroll.conf` and so
outlives updates.

The device-agent marks the booted slot good once it has reached the platform
(WP-2.4, device-agent 1.6.0); a slot it never marks falls back.

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

`just build amd64-efi installer` (or `arm64-efi installer`) builds the FlockOS
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
