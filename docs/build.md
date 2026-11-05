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
| signing material | `build/signing.sh` | `keyring.pem` the image trusts, the signer certificate and key: throwaway on every build except a release (ADR-0006, `docs/signing.md`) |
| rootfs | `build/mkrootfs.sh` | Debian 13 minbase tree from `mmdebstrap` with `profiles/base/packages`, its per-architecture list, the target's `targets/<target>/packages` and the variant's `profiles/<variant>/packages` (no Recommends), Docker CE from download.docker.com at the versions in `profiles/base/versions`; for `nvidia` also NVIDIA's driver, its open kernel modules and the container toolkit (see below) |
| customisation | `build/customize.sh` | `overlay/` copied in, RAUC `system.conf` and keyring, `repart.d`, os-release, no accounts but a locked root, kernel at `/vmlinuz`, units enabled and masked, IronFlock baked in (`build/bake.sh`), package manifest, timestamps clamped to the commit time |
| disk image | `build/mkimage.sh` (EFI targets), `build/mkimage-rpi.sh` (Raspberry Pi: FLOCKOS with `autoboot.txt`, boot-a from `/boot/firmware`, an empty boot-b, slot A) | FLOCKOS partition (ESP: GRUB, `grub.cfg`, `grubenv`), slot A as ext4 of the full slot size, assembled by `genimage` from `targets/<target>/genimage.cfg`, compressed |
| bundle | `build/mkbundle.sh` | verity RAUC bundle of slot A's filesystem, `compatible=flockos-<target>-<variant>[-rt]`, signed and verified against the image keyring; none for `rpi-arm64` until its A/B arrives (WP-5.2) |

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
| `/var/log/journal` | `/data/log/journal` |
| `/var/cache/flockos` | `/data/cache` (downloaded bundles) |
| `/var/lib/fwupd` | `/data/fwupd` |

SSH host keys are made on the first boot in `/data/etc/ssh` and `sshd` is
pointed there. The machine-id is generated on the first boot in the slot; RAUC's
post-install handler (`/usr/lib/flockos/rauc-post-install`) copies it and the
hostname into the slot it has just written, so an update keeps the device's
identity. RAUC's own state is in `/data/rauc`.

## Boot and A/B

GRUB is one EFI binary at the removable-media path `EFI/BOOT/BOOTX64.EFI` (no
boot entry is needed) with its modules built in. `grub.cfg`
(`targets/amd64-efi/grub/grub.cfg`) is RAUC's reference A/B script: it picks the
first slot in `ORDER` that is good and not yet tried, sets its `_TRY` flag in
`grubenv`, and boots that slot's `/vmlinuz` with `root=PARTUUID=…` and
`rauc.slot=A|B`. A slot that is never marked good is skipped on the next boot.
Until the device-agent marks the slot good after reaching the platform (Phase 2),
`flockos-mark-good.service` does it once Docker runs.

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
unit; enroll puts them back without network. `/etc/flockos/enroll.conf` with
`hostname-from-flock=yes` also sets the hostname.

Until the device-agent marks the slot good after reaching the platform
(WP-2.4), `flockos-mark-good.service` does it once Docker runs.

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
notebook feature) from being enabled on a slot's first boot. The modules are
unsigned; FlockOS 1.x boots without Secure Boot.

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
Debian archive is not pinned to a snapshot, so two builds of one commit on
different days can differ in package versions; `packages.tsv` records what went
in. Docker CE and its companions are pinned in `profiles/base/versions`, the
NVIDIA packages in `profiles/nvidia/versions`.
