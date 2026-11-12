# IronFlockOS master plan

Status: draft v1.1, 2026-11-04 (v1.1 adds firmware updates and the real-time kernel option). Owner: Marko Petzold. Scope: this repository and the
cross-repo changes it needs in device-init (now IronFlock/ironflock-cli), device-agent, flasher, workflows and
the GCP project.
****
This document is the plan of record for turning the ReswarmOS repository into the
IronFlockOS image pipeline. The evidence behind every "today" statement is in
[current-state-audit.md](current-state-audit.md). The decisions that shape the plan
are recorded as ADRs in [adr/](adr/).

## 1. Goals and non-goals

### Goals

| # | Goal | Done when |
|---|------|-----------|
| G1 | Working, reproducible OS images for **amd64** and **arm64** | A release produces every image in the target matrix from one commit, in CI |
| G2 | Support **Raspberry Pi** (64-bit models), **generic AMD/ARM edge PCs**, **NVIDIA GPU in containers** on x86, and **Jetson Orin** | Each target boots, enrolls into IronFlock, runs a GPU container where applicable |
| G3 | **RAUC A/B updates** triggered by the device-agent, including kernel updates and automatic rollback | A device updates from release N to N+1 over the platform and falls back to N when N+1 fails to boot |
| G4 | **Reuse device-init** (now the `ironflock` CLI, IronFlock/ironflock-cli) instead of duplicating host setup; ship in the image what it would install anyway | The image contains no setup logic of its own beyond calling `ironflock`; first boot works offline |
| G5 | Images are **installable by FlockFlasher** | FlockFlasher lists IronFlockOS images from the signed catalog, flashes them, and injects the `.flock` file; PCs get an installer USB that writes the image to any internal disk |
| G6 | **CI and security harness** like every other IronFlock repo; all building happens in GitHub Actions | `ci.yml`, `security.yml`, `release.yml` call `IronFlock/workflows@v1`; `main` is protected by `ci-ok` and `security / report`; release artefacts are signed and carry SBOM and provenance |
| G7 | **Firmware updates** for the hardware the OS runs on are delivered and tracked through the same system | Boot firmware an OS release depends on ships inside the RAUC bundle; component firmware is inventoried and updatable from the platform through fwupd (section 3.10) |
| G8 | **Real-time kernel option** (PREEMPT_RT) per target | Every target offers a `-rt` image with a documented latency figure and tuning profile; `-rt` images update through the same RAUC path (section 3.11) |

### Non-goals (explicitly out of scope)

- 32-bit ARM boards (Raspberry Pi 1, 2, Zero W, 3 in 32-bit mode). device-init stages
  the agent for amd64 and arm64 only; the Pi 3 and Zero 2 W are served in 64-bit mode.
- In-place migration of existing ReswarmOS 0.5.x or 0.0.7 devices to IronFlockOS. They have a
  different partition layout and architecture; they are reflashed.
- Jetson Nano, TX2, Xavier (JetPack 4/5, EOL kernels). Orin and newer only.
- A desktop or GUI session on the device.
- Secure Boot with IronFlock's own keys, and measured boot. Listed as later hardening,
  not part of this program. The EFI targets boot with Secure Boot on through Debian's
  signed boot chain, for convenience (ADR-0011).

## 2. Where we are

A one-paragraph summary; the audit has the details.

The repo holds two unrelated builders. `buildroot/` wraps a Buildroot commit from early
2022, builds 32-bit Raspberry Pi images only, and takes one to two hours per build on a
developer machine with a TTY. Its Jetson and x86_64 configurations cannot build. `cubic/`
customises an Ubuntu 20.04.3 server ISO through a GUI wizard that cannot run headless;
the published x86 installer is from June 2022. RAUC exists in both trees on paper: the
bundle version is mangled, both signing certificates are expired, the in-image update
units use shell syntax systemd never executes, the x86 GRUB fallback script has a typo
that disables fallback, and the OS-side update poller the device-agent depends on was
deleted from this repo in October 2026. The device setup tool (`reswarmify`) was
extracted to `IronFlock/device-init` (now `IronFlock/ironflock-cli`) and is current; the image does not use it. A
private `IronFlock/ironflockos` repo contains a second, abandoned Buildroot attempt with a
committed RAUC private key. There is no CI, no branch protection, and "IronFlockOS" appears
nowhere in the code.

The surrounding repos are in good shape and define the contracts the new image must meet:

- **device-init** installs on "Debian or Ubuntu-based systems with systemd" through
  `ironflock-init`, which brings packages, Docker, the signed agent binary, an SSH user,
  WiFi and NetworkManager settings, and lets the agent install its own unit.
- **device-agent** installs RAUC bundles over D-Bus and expects an OS-side poller to tell
  it what is available. It parses `/etc/os-release` `VERSION` as `v<ver>-g<sha>-<buildtime>`.
- **flasher** (FlockFlasher) reads `dl/reswarmos/supportedBoardsImages.json`, flashes
  gzip images, and copies the `.flock` file to the first mounted partition. Its ISO path
  assumes an isolinux layout that modern ISOs do not have.
- **workflows** provides the harness: thin `ci.yml` / `security.yml` / `release.yml`
  callers, version-file releases via `just release-patch`, OpenPGP and KMS signing,
  SBOM and provenance, hash-pinned actions, rulesets.

## 3. Target architecture

### 3.1 Product definition

IronFlockOS is a Debian-based, image-based, A/B-updated appliance OS whose only job is to
run the IronFlock device-agent and Docker. One version number covers all images of a
release. See [ADR-0001](adr/0001-debian-based-image-for-all-targets.md).

**Targets** (hardware class; one partition layout and boot method each):

| Target id | Arch | Boot | A/B mechanism | Delivery |
|-----------|------|------|---------------|----------|
| `amd64-efi` | amd64 | UEFI + GRUB | RAUC `grub` backend, grubenv on the ESP | raw image, installer USB |
| `arm64-efi` | arm64 | UEFI + GRUB (SystemReady boards, VMs) | same as `amd64-efi` | raw image, installer USB |
| `rpi-arm64` | arm64 | Raspberry Pi firmware, tryboot | RAUC `custom` backend over `autoboot.txt` | raw image (SD/USB/NVMe) |
| `jetson-orin` | arm64 | NVIDIA UEFI (L4T r36) | RAUC `custom` backend over `nvbootctrl -t rootfs` | SD image (Orin Nano devkit), flash package (NX/AGX modules) |

**Variants** (software profile layered on a target):

| Variant | Content | Targets |
|---------|---------|---------|
| `base` | Debian stable, systemd, NetworkManager, OpenSSH, Docker CE, RAUC, device-agent, `ironflock` | all |
| `nvidia` | `base` + NVIDIA open kernel modules, driver userspace, `nvidia-container-toolkit`, persistence daemon | `amd64-efi` (Jetson has NVIDIA userspace in `base` by construction) |
| `installer` | `base` + the installer program + an embedded payload image; no RAUC | `amd64-efi`, `arm64-efi` |

**Kernel** (third axis, `std` or `rt`): every target can be built with the standard kernel
or a PREEMPT_RT kernel (section 3.11). The axis appears as a `-rt` suffix; images without
the suffix are `std`. To keep the matrix small, `rt` is offered for `base` on every target
and for `nvidia` only where NVIDIA supports it.

**Naming.** RAUC `compatible` is `ironflockos-<target>-<variant>[-rt]`, for example
`ironflockos-amd64-efi-nvidia` or `ironflockos-amd64-efi-base-rt`. Artefacts are
`ironflockos-<target>-<variant>[-rt]-<version>.img.gz` and `.raucb`. The target id is also the
directory name under `targets/`.

**Versioning.** Semantic version in a single `VERSION` file at the repo root; bumped by
`just release-patch|minor|major`, released by the merge of the PR titled
`release ironflockos v<version>`, exactly like the other repos. One release = every
target×variant image built from the same commit.

**`/etc/os-release` contract** (what the agent, `ironflock` and the platform read):

```
NAME="IronFlockOS"
ID=ironflockos
ID_LIKE=debian
PRETTY_NAME="IronFlockOS 1.0.0 (amd64-efi, base)"
VERSION_ID="1.0.0"
IMAGE_ID=ironflockos-amd64-efi-base
IMAGE_VERSION=1.0.0
VARIANT=base
VARIANT_ID=base
BUILD_ID=20261120T100000Z-g1a2b3c4
VERSION="v1.0.0-g1a2b3c4-20261120T100000"
HOME_URL="https://www.ironflock.com"
```

`VERSION` keeps the legacy `v<ver>-g<sha>-<buildtime>` shape until the device-agent
reads `IMAGE_ID`, `IMAGE_VERSION` and `BUILD_ID` (section 5); then it becomes free text.

### 3.2 Image anatomy

Every image has a FAT partition first, two root slots, and one persistent data partition.
The FAT partition is labelled `IRONFLOCKOS` and is where FlockFlasher drops the `.flock` file.

**`amd64-efi` and `arm64-efi` (GPT):**

| # | Label | FS | Size | Content |
|---|-------|----|------|---------|
| 1 | `IRONFLOCKOS` (ESP) | FAT32 | 256 MiB | shim and Debian's signed GRUB (ADR-0011), `grub.cfg` (RAUC A/B script), `grubenv`, incoming `<device>.flock` |
| 2 | `rootfs-a` | ext4 | 4 GiB base, 8 GiB nvidia | Debian root including `/boot/vmlinuz` and initrd |
| 3 | `rootfs-b` | ext4 | same | empty at flash time |
| 4 | `data` | ext4 | rest of disk, grown on first boot by `systemd-repart` | everything that must survive an A/B switch |

GRUB reads `ORDER`, `A_OK/A_TRY`, `B_OK/B_TRY` from `grubenv` on the ESP, decrements the
try counter, and loads the kernel from the chosen slot. This is RAUC's reference GRUB
integration; the kernel lives inside the slot, so a bundle updates the kernel too.

**`rpi-arm64` (GPT where the model's firmware supports it, else MBR with 4 partitions +
extended):**

| # | Label | FS | Content |
|---|-------|----|---------|
| 1 | `IRONFLOCKOS` | FAT32, 64 MiB | `autoboot.txt` only (firmware reads it from partition 1), incoming `.flock` |
| 2 | `boot-a` | FAT32, 256 MiB | firmware, kernel, initramfs, `config.txt`, `cmdline.txt` for slot A |
| 3 | `boot-b` | FAT32, 256 MiB | same for slot B |
| 4 | `rootfs-a` | ext4 | |
| 5 | `rootfs-b` | ext4 | |
| 6 | `data` | ext4 | |

`autoboot.txt` carries `[all] boot_partition=2` and `[tryboot] boot_partition=3`
(or the reverse). RAUC's `custom` backend script implements `get-primary`, `set-primary`,
`get-state`, `set-state` by editing `autoboot.txt` and issuing `reboot "0 tryboot"`; the
RAUC bundle holds `boot.vfat` and `rootfs.ext4` as a slot group so a kernel update is
atomic with its rootfs. This follows the Bootlin and Eclipse Oniro implementations and
avoids U-Boot entirely. Pi 4, Pi 5, CM4, CM5 are first class; Pi 3 and Zero 2 W boot
64-bit but their firmware does not support `autoboot.txt`, so they get the U-Boot RAUC
backend as an optional later step or run without A/B.

**`jetson-orin`:** NVIDIA's flash layout (`APP`/`APP_b` with `ROOTFS_AB=1`, ESP and
bootloader partitions managed by L4T) plus an added `data` partition and a `IRONFLOCKOS`
FAT partition. Slot switching uses `nvbootctrl -t rootfs set-active-boot-slot` behind a
RAUC `custom` backend; UEFI falls back to the other slot after three failed warm boots.
See section 3.7.

**The `data` partition** is mounted at `/data`. The image bakes in the redirections so
`ironflock` and the agent need no knowledge of it:

| Path in root | Lives at | Why |
|--------------|----------|-----|
| `/opt/ironflock` | `/data/ironflock` | agent binary, `device-config.flock`, `installed.json`, Docker data-root chosen by `ironflock` (`/opt/ironflock/device-agent/docker-apps`) |
| `/home` | `/data/home` | the SSH user `ironflock enroll` creates |
| `/etc/NetworkManager/system-connections` | `/data/network/connections` | WiFi profile written by `ironflock enroll` |
| `/etc/ssh/ssh_host_*` | `/data/etc/ssh` | stable host identity across slots |
| `/etc/machine-id` | `/data/etc/machine-id` | stable `/etc/machine-id` for journald and NetworkManager |
| `/var/log/journal` | `/data/log/journal` | persistent journal |
| `/var/cache/ironflockos` | `/data/cache` | downloaded RAUC bundles |
| `/var/lib/fwupd` | `/data/fwupd` | fwupd history and pending offline firmware updates |
| `/etc/ironflockos/rt.conf` | `/data/ironflockos/rt.conf` | platform-managed real-time CPU set and tuning (section 3.11) |
| `/etc/hostname`, user accounts, sudoers | re-applied on each first boot of a slot by `ironflock enroll` from `/data/ironflock/.../device-config.flock` | keeps the rootfs stateless |

The root filesystem is read-write in the first releases. Read-only root with dm-verity
is listed under later hardening (section 8).

### 3.3 Build system

Decision: `mmdebstrap` + `genimage` + a thin shell/`just` framework, no Buildroot, no
Cubic, no GUI. See [ADR-0005](adr/0005-builder-mmdebstrap-genimage.md).

Pipeline per target×variant:

1. **rootfs**: `mmdebstrap --mode=unshare --arch=<arch> --variant=minbase` with the
   profile's package list, apt sources (Debian, download.docker.com, Raspberry Pi,
   NVIDIA), hooks that run the overlay copy and `ironflock bake`. Produces a
   reproducible tar given `SOURCE_DATE_EPOCH`. Runs unprivileged; cross-arch via
   `qemu-user-static` when the runner is not native.
2. **slot images**: `mke2fs -d` from the tar into `rootfs.ext4` of the fixed slot size;
   `mkfs.vfat` + `mcopy` for boot partitions.
3. **disk image**: `genimage` with `targets/<target>/genimage.cfg` assembles the GPT
   image. Sparse output, then `gzip -k` (and `xz` once FlockFlasher accepts it).
4. **RAUC bundle**: `rauc bundle` with `manifest.raucm` generated from `VERSION`,
   target and variant; `verity` format; signed with the KMS-backed key through PKCS#11
   on release, with an ephemeral key on pull requests.
5. **metadata**: `build/mkmanifest.py` writes the catalog entry (sha256, size,
   buildtime, URLs) and the SBOM comes from `trivy rootfs` (CycloneDX).

Repository layout after the rewrite:

```
ironflockos/
  VERSION                      one version for all images
  Justfile                     lint, test, build TARGET VARIANT, bundle, qemu-test, release-*
  tools.lock                   pinned tool versions (mirrors the harness convention)
  .github/workflows/           ci.yml, security.yml, release.yml (thin callers)
  build/                       mkrootfs.sh, mkimage.sh, mkbundle.sh, mkmanifest.py, lib.sh
  profiles/                    base/, nvidia/, installer/: packages, apt sources, hooks
  targets/                     amd64-efi/, arm64-efi/, rpi-arm64/, jetson-orin/:
                                 target.conf, genimage.cfg, boot files, rauc/system.conf, repart.d/
  overlay/                     rootfs overlay shared by all targets (units, ironflockos-* scripts)
  overlay-<target>/            per-target overlay (rauc backend scripts, boot config)
  test/                        qemu/ (boot + A/B tests, bats), fixtures/
  docs/                        this plan, audit, ADRs, per-target notes
```

The old `buildroot/`, `cubic/` and `ironflockos-vm-setup.md` are deleted in Phase 0 together
with the harness skeleton: they cannot pass the gate, and the security scan would stop on
their embedded credentials. The git history keeps them; the last commit with them is
`82b9a03`.

### 3.4 Provisioning: reuse the IronFlock CLI (formerly device-init)

Principle: **the image never implements host setup; it calls `ironflock`** (IronFlock/ironflock-cli;
`ironflock-init` of IronFlock/device-init until the CLI's WP-5.1). The
image only adds (a) a bake step at build time so that first boot needs no network and
(b) a first-boot unit that enrolls from the `.flock` file. See
[ADR-0001](adr/0001-debian-based-image-for-all-targets.md) for why this requires a
Debian-style base.

**At build time**, inside the mmdebstrap chroot: `ironflock bake --arch <arch>`
(`build/bake.sh`) installs the package set `ironflock` would install (`jq
ca-certificates curl gnupg lsb-release net-tools iproute2 dnsutils network-manager
openssh-server`), Docker CE from the Docker apt repo (pinned version from the profile),
the agent binary of the manifest's production channel (verified via `.sha256` and
`.sig`), `/etc/docker/daemon.json`, NetworkManager drop-ins, the restart drop-ins, the
motd, and seeds `installed.json` with `source: image`. It does not start services,
create users, or prompt.

**At first boot** of a slot (fresh flash or after an A/B switch), `ironflockos-enroll.service`
(`After=docker.service network-pre.target`, `ConditionPathExists=!/data/ironflock/enrolled`)
runs `ironflock enroll -c <file>` where `<file>` is the newest `*.flock` on the
`IRONFLOCKOS` partition or, if none, the persisted `/data/ironflock/device-agent/device-config.flock`.
Enroll creates the SSH user, authorized key, sudoers, WiFi profile, hostname (from the
`.flock` `name`, opt-in), installs and starts `ironflock-device-agent.service`, and
shreds the `.flock` file on the FAT partition after it has been copied to `/data` with
mode 0600. Without a `.flock` file the device stays unenrolled; the agent is not started
and the device is reachable only on the console. There is no default user and no root
password.

**device-init changes this requires** (tracked in that repo):

| Change | Why |
|--------|-----|
| `bake` subcommand, chroot-safe (`--yes`, no `systemctl start`, no `/dev/tty`) | build-time preinstall |
| `enroll` subcommand, idempotent, `--hostname-from-flock`, `--shred-source` | first boot and re-enroll after slot switch |
| detect distro via `/etc/os-release` `ID`/`ID_LIKE` instead of the first word of `/etc/issue`; `ironflockos` maps to apt | `/etc/issue` detection is fragile and IronFlockOS is not "Debian" by name |
| skip the agent download when the baked binary already matches the manifest; tolerate being offline at enroll time | first boot offline |
| record `docker: preinstalled` in `installed.json` so `remove` leaves image Docker alone | correctness of `ironflock-init remove` |
| e2e target `ironflockos-amd64` next to `vdm-amd64`, `ubuntu-24.04`, `debian-13` | device-init keeps proving it works on the image |

### 3.5 OS updates: RAUC + device-agent

Flow (replaces the deleted `reswarmos-update-check` poller and the `/etc/reswarmos-update`
file handshake):

1. **Catalog.** The release pipeline publishes `dl/ironflockos/manifest.json`, signed with
   the same detached-signature scheme the agent already verifies for
   `device-agent/manifest-v2.json`. It names the version of each channel (production,
   test) and, per release and `IMAGE_ID`, `build_id`, `image` (url, sha256, size),
   `bundle` (url, sha256, size, compatible) and `min_agent`. The shape is
   [`manifest.schema.json`](manifest.schema.json) ([ADR-0009](adr/0009-phase-2-decisions-hostname-channels-firmware.md)).
2. **Check.** The agent reads `IMAGE_ID`, `IMAGE_VERSION`, `BUILD_ID` from
   `/etc/os-release`, fetches and verifies the manifest on its existing schedule, and
   reports `currentRelease`/`latestRelease` through `get_os_release`.
3. **Download.** On `download_os_update` the agent streams the bundle to
   `/var/cache/ironflockos/` (on `/data`, not tmpfs), verifies sha256, and reports progress
   on `re.mgmt.<serial>.download_os_update_progress` as today. RAUC's built-in HTTPS
   streaming of `verity` bundles is the follow-up that removes the local copy.
4. **Install.** `install_os_update` calls `de.pengutronix.rauc.Installer.InstallBundle`
   as today; RAUC verifies the signature against `/etc/rauc/keyring.pem` and the
   `compatible` string, writes the inactive slot (`boot` + `rootfs` as a group where
   the target has a boot slot), and marks it primary with try counters. Failures are
   returned to the platform (today the agent swallows them).
5. **Reboot.** `perform_os_update` (defined, unimplemented today) chains download,
   install and reboot behind one progress topic; `system_reboot` stays available.
6. **Health gate.** The new slot boots with `rauc.slot=<name>` on the command line.
   `rauc status mark-good` is **not** run by a unit at boot any more; the agent calls
   `Mark("good")` after it has connected to the platform and Docker is healthy. If the
   agent never gets there, the bootloader's try counter expires and the old slot boots.
   The agent on the old slot reports the rollback.
7. **Legacy.** Devices on ReswarmOS keep polling `gs://reswarmos/supportedBoardsImages.json`;
   that file is frozen and the bucket stays read-only.

**device-agent changes this requires:** manifest fetch and comparison (replacing the
two files), persistent download location with sha256 check, honest error returns,
`perform_os_update` handler, post-connect `mark-good`, slot status in device info
(`GetSlotStatus`, `GetPrimary` are already bound), tolerant `os-release` parsing, and a
`ironflockos` layout in `layout.go` (`/data`-based paths). The `updatesig` package and KMS
signing recipes are reused for the manifest.

**PKI.** See [ADR-0006](adr/0006-rauc-pki-in-cloud-kms.md). An IronFlockOS root CA
(20 years) signs a bundle-signing certificate (3 years, rotated) whose private key lives
only in Cloud KMS (`ironflock-release/ironflockos-rauc-signer`). CI signs through RAUC's
PKCS#11 support (`RAUC_PKCS11_MODULE=libkmsp11.so`, `--key 'pkcs11:...'`) with
Workload Identity Federation, so no key material exists on runners. The device keyring
holds the CA, so signer rotation needs no device update. `system.conf` sets
`use-bundle-signing-time=true` because Raspberry Pis have no RTC. Pull-request builds sign
with a throwaway key and embed its certificate, so PR images cannot install release
bundles and vice versa. The two expired 2021/2025 certificates and the key committed to
`IronFlock/ironflockos` are retired and never reused.

### 3.6 Delivery: FlockFlasher and the installer USB

Decision: every artefact FlockFlasher handles is a raw `.img.gz`; PCs are installed from a
IronFlockOS installer USB that is itself a raw image. See
[ADR-0004](adr/0004-raw-image-plus-installer-usb.md). This removes the ISO repack path
and its isolinux assumption from the flasher.

**Catalog contract.** `dl/ironflockos/manifest.json` carries, next to the device-agent's
view, a `boards` view in the shape FlockFlasher already parses (`boards[]` with
`latestImages[]`, `ImageInfo` fields `buildtime, download, file, osname, osvariant,
sha256, size, update, version`, plus `image_id`, `variant` and `kernel`), inside a signed
envelope ([`manifest.schema.json`](manifest.schema.json), ADR-0009). The legacy file
`dl/reswarmos/supportedBoardsImages.json` is left frozen for old flasher versions.

**Installer USB** (`installer` variant). Boots the same IronFlockOS base, starts
`ironflockos-installer` instead of the agent, and:

1. reads `installer.conf` and `*.flock` from the `IRONFLOCKOS` partition of the USB stick
   (the flasher put them there like for any image);
2. lists internal disks (NVMe, SATA, eMMC; excludes the boot medium), picks the target
   by rule (`installer.conf`: `disk=largest|/dev/nvme0n1|by-id:...`, `confirm=yes|no`)
   or asks on the console;
3. writes the embedded payload (`ironflockos-<target>-<variant>-<version>.img.zst` on the
   installer's data partition) with `bmaptool`/`dd`, copies the `.flock` file and
   `installer.conf` onto the new system's `IRONFLOCKOS` partition, registers the EFI boot
   entry with `efibootmgr`, and powers off (or reboots when `installer.conf` says so).

The installed system then behaves exactly like a directly flashed one: `systemd-repart`
grows `data`, `ironflockos-enroll` enrolls. The installer supports choosing `base` or
`nvidia` payloads when both are embedded. This is the pattern balenaOS uses for its
"flasher" images.

**FlockFlasher changes this requires** (tracked in that repo):

| Change | Why |
|--------|-----|
| read `dl/ironflockos/manifest.json` and verify its signature | new catalog, no unsigned catalog over the network |
| let the user pick a variant (`base`, `nvidia`, `installer`) instead of using `latestImages[0]` | the matrix has more than one image per board |
| write the `.flock` file to the partition labelled `IRONFLOCKOS` (fallback: first FAT mount) and make the Windows mount path work | robust config injection |
| drop the ISO repack path or keep it behind a legacy flag | installer is a raw image now |
| accept `.img.xz` in addition to `.gz` via etcher-sdk | smaller downloads |
| rename ReswarmOS strings to IronFlockOS; keep `.reswarm` association | branding |

### 3.7 Hardware enablement

**`amd64-efi`** (Phase 1). Debian 13 (trixie) `linux-image-amd64` (6.12 LTS, Debian
security updates), Debian's signed boot chain (`shim-signed`, `grub-efi-amd64-signed`;
ADR-0011), `firmware-linux`
non-free blobs for NICs and WiFi, `intel-microcode`/`amd64-microcode`. Boot-tested in
QEMU with OVMF in CI. Generic enough for any UEFI x86 IPC; legacy BIOS is not supported.

**`nvidia` on `amd64-efi`** (Phase 4). NVIDIA's CUDA apt repo for `debian13` provides
`nvidia-driver-cuda` and `nvidia-kernel-open-dkms`; the DKMS module is built **at image
build time** in the chroot against the image's exact kernel, then headers and compiler
are purged, so no device compiles anything. `nvidia-container-toolkit` from NVIDIA's
`libnvidia-container` apt repo; `nvidia-ctk runtime configure --runtime=docker` is
unnecessary because `ironflock bake` already adds the `nvidia` runtime when
`/usr/bin/nvidia-container-runtime` exists. `nouveau` blacklisted, `nvidia-persistenced`
enabled. Acceptance: `docker run --rm --gpus all nvidia/cuda:12-base nvidia-smi` on a
real GPU host (no GPU in CI; a self-hosted or manual gate). Kernel bumps rebuild the
module automatically because the kernel is pinned per release.

**`rpi-arm64`** (Phase 5). Debian 13 arm64 base plus the Raspberry Pi apt repository
(`archive.raspberrypi.com/debian`) for `linux-image-rpi-v8` (Pi 3/4/CM4/Zero 2 W) and
`linux-image-rpi-2712` (Pi 5/CM5), `raspi-firmware`, `rpi-eeprom`. The tryboot A/B
layout from 3.2; `cmdline.txt` per boot slot is written by a RAUC post-install hook so
`root=` always matches the slot. Tested on real hardware (no QEMU for the firmware boot
path); CI builds and runs a chroot-level smoke test. Pi 4 EEPROM must be new enough for
`autoboot.txt` (2020-10 or later; `rpi-eeprom-update` in the image).

**`arm64-efi`** (Phase 7). The `amd64-efi` target definition with the architecture
swapped: `linux-image-arm64`, `grub-efi-arm64`. Covers SystemReady boards, Ampere/
Rockchip boxes with EDK2, and arm64 VMs. Tested in QEMU `virt` with AAVMF.

**`jetson-orin`** (Phase 6). Jetson Linux r36.x (JetPack 6, Ubuntu 22.04 userspace) is
the only supported BSP for Orin, so this target's rootfs is Ubuntu 22.04 arm64 built with
mmdebstrap, with NVIDIA's `apply_binaries.sh` layering the L4T packages, and our overlay
on top. A/B uses the BSP's rootfs redundancy (`ROOTFS_AB=1`, `APP`/`APP_b`) and
`nvbootctrl -t rootfs` behind a RAUC `custom` backend; the bootloader stays NVIDIA's.
Two deliverables: an SD-card image for the Orin Nano Developer Kit made with
`jetson-disk-image-creator.sh` (flashable by FlockFlasher, QSPI firmware must match the
JetPack generation), and a flash package (`l4t_initrd_flash.sh` plus our rootfs and layout
XML) for Orin NX/AGX modules on NVMe/eMMC, which must be flashed from a Linux host with
the module in recovery mode. The BSP is downloaded in CI from NVIDIA's public archive
and cached. Verify at phase start whether JetPack 7 (L4T r38, Ubuntu 24.04) has gained
Orin support; if so, prefer it to align with Debian 13-era userspace.

### 3.8 CI/CD and security harness

Thin callers, as in every IronFlock repo (`device-init` is the closest template):

**`ci.yml`** on `pull_request` to `main`:
- `gate`: a new reusable `shell-gate.yml` in `IronFlock/workflows` (the README says
  gates for shell repos are added when the first repo adopts; this is that repo). Jobs
  `lint` (`shellcheck`, `shfmt -d`, `yamllint`, `just --fmt --check`, `genimage` config
  parse), `unit` (`bats` tests of `build/*.sh` and the RAUC backend scripts), `build`
  (`just build amd64-efi base` as the smoke build, about 15 minutes).
- `image-test`: boots the built `amd64-efi` image in QEMU/OVMF on the runner (KVM is
  available on GitHub-hosted Linux runners), asserts multi-user reached, `rauc status`
  shows slot A good, Docker runs a preloaded `hello-world`, installs the bundle from the
  same build into slot B, reboots, asserts slot B, then breaks slot B and asserts
  fallback to A after the try counter. Runs on every PR.
- `workflows` (`workflows-lint.yml`), `intent` (`release-intent.yml`, `version-file:
  VERSION`), `release-build` (dry run of `release.yml` on release PRs), `ci-ok`.

**`security.yml`** on PR, weekly cron, dispatch: `security.yml@v1` with `languages:
none`, gitleaks, semgrep (shell rules), trivy config and licence scans, `fail-on`
report-only for the first two weeks then the standard blocking list. Plus a repo-local
`rootfs-scan` job: `trivy rootfs` over the built root tree producing SARIF (uploaded via
the harness `report` convention) and a CycloneDX SBOM. Proposed harness extension:
`security.yml` input `rootfs-recipe` so this becomes shared.

**`release.yml`** on push to `main` with `paths: [VERSION]`, `workflow_call`, dispatch:
1. `verify` (harness `release.sh mode`).
2. `build` matrix over target×variant×kernel; `ubuntu-24.04` for amd64, `ubuntu-24.04-arm`
   for arm64 (native, free on public repos; see [ADR-0002](adr/0002-repo-home-ironflock-flockos.md)).
   Each job builds the image, scans it, writes the SBOM, creates and signs the RAUC
   bundle through KMS/PKCS#11 (WIF, `id-token: write`), and attests image and bundle
   digests with `actions/attest-build-provenance`. Dry runs sign with an ephemeral key.
3. `stage`: upload to `gs://ironflock-downloads/staging/ironflockos/<version>/`.
4. `e2e`: QEMU boots the staged `amd64-efi` image, enrolls into the test flock
   (`IRONFLOCK_E2E_FLOCKS` from the `release` environment, as device-init does), checks
   the device is online through the API, and performs a RAUC update **from the previous
   release's image to this one** and back. (Since [ADR-0019](adr/0019-every-test-runs-before-the-merge.md),
   every test runs before the merge: a release that reuses its pull request's images
   skips `e2e`.)
5. `promote`: copy to `gs://ironflock-downloads/ironflockos/<target>/<version>/`, write and
   sign `dl/ironflockos/manifest.json`, create the GitHub Release with checksums, SBOMs and
   attestation links.
6. `tag` (`release-tag.yml@v1`).

**Repo settings.** Default branch `main`, rulesets "main: pull requests with green
checks" (required `ci-ok`, `security / report`, squash only) and "release tags v*",
`release` environment with the release App secrets and the e2e flock secret, WIF
service account `ironflockos-release@record-1283` with `roles/cloudkms.signer` on the RAUC
key and object admin on the `ironflockos/` and `staging/ironflockos/` prefixes.

**Runner limits to design around.** 14 GB free disk on standard runners: build on
`/mnt`, keep images sparse, gzip in a stream, clean apt caches; 6-hour job limit is far
away (builds are 10 to 20 minutes). Jetson builds pull a 2 GB BSP; cache it with
`actions/cache` keyed on the L4T version.

### 3.9 Security posture of the image

- No root password, no default user, no password SSH. The only account is the one
  `ironflock enroll` creates from the `.flock` key. `PermitRootLogin no`.
- `.flock` secrets leave the FAT partition after enrollment; copies are 0600 on `/data`.
- Nothing in the image logs passwords or keys (the legacy scripts did).
- No telemetry calls from login shells (the legacy motd called `ipinfo.io` three times
  per login).
- Unattended upgrades off; the OS changes only through signed RAUC bundles.
- AppArmor on the Debian images: Docker's default profile on every container that is
  not privileged (ADR-0020).
- `nftables` default-deny inbound except SSH and what Docker publishes (opt-in in Phase 2;
  Docker's own chains are respected).
- Reproducible rootfs (`SOURCE_DATE_EPOCH`), SBOM per image, provenance attestations,
  weekly rescans of the latest release's SBOM for new CVEs.
- Later hardening (not in this program): read-only root with dm-verity (RAUC `verity`
  bundles already carry the hash tree), Secure Boot with our own keys on x86, TPM-bound
  device identity.

### 3.10 Firmware updates

"Firmware" covers three different things, and the system treats each in its own lane.

| Lane | Examples | Mechanism | Redundancy |
|------|----------|-----------|------------|
| 1. Runtime-loaded firmware | WiFi, Bluetooth and NIC blobs in `/lib/firmware`, CPU microcode, NVIDIA GSP firmware | Files in the rootfs, so every RAUC bundle already carries them; versions pinned per release | Full (A/B) |
| 2. Boot firmware an OS release depends on | Raspberry Pi EEPROM bootloader, Jetson QSPI bootloader stack (MB1, MB2, BPMP, UEFI), PC UEFI where the vendor supplies capsule files | Payload shipped inside the RAUC bundle, staged by a RAUC post-install hook, applied by the firmware on the same reboot that switches slots | The vendor's own: Jetson bootloader A/B, Pi `recovery.bin` path, UEFI capsule fallback. Not full |
| 3. Component firmware | NVMe and SATA SSDs, NICs, LTE modems, USB DFU devices, TPMs, docks, PC UEFI published to LVFS | `fwupd` on the device, driven by the agent over D-Bus; metadata from LVFS or an IronFlock-signed remote | Device-specific, often none |

**Lane 2 per target.**

- *Raspberry Pi.* The `rpi-eeprom` package is pinned per release. The hook runs
  `rpi-eeprom-update -d -f <pieeprom.bin>`, which stages `pieeprom.upd` plus `recovery.bin`
  on the boot FAT partition; the ROM applies the update at the next boot and renames
  `recovery.bin` to `RECOVERY.000` on success. Which FAT partition the ROM consults when
  `autoboot.txt` selects a boot slot has to be verified at the start of Phase 5. EEPROM
  configuration (`BOOT_ORDER` for NVMe/USB boot, `POWER_OFF_ON_HALT`) is managed the same way.
- *Jetson Orin.* CI generates `TEGRA_BL.Cap` with `l4t_generate_soc_capsule.sh` from the
  pinned BSP. The hook copies it to `EFI/UpdateCapsule/` on the ESP and sets bit 2 of the
  `OsIndications` UEFI variable; UEFI writes the inactive bootloader slot and falls back on
  failure. QSPI and rootfs L4T versions stay in lock-step. There are field reports of boot
  loops after power loss during a capsule update on r36.4.0, so lane 2 on Jetson only
  runs inside a platform-controlled maintenance window.
- *PCs.* Where the board vendor ships capsule files, they are packaged as fwupd `.cab`
  files and staged by fwupd (`fwupd-offline-update` boots `fwupdx64.efi` once via
  `BootNext`, applies, and returns to the normal boot order, which keeps GRUB's A/B logic
  intact). Vendors that publish to LVFS are handled by lane 3. Vendors that do neither get
  no in-field BIOS update, and the per-target docs say so.

**Lane 3.** `fwupd` (2.0 series in Debian 13; Debian's signed EFI helper
`fwupd-<arch>-signed`, so capsules also start under Secure Boot, ADR-0011) with the `uefi-capsule`, `nvme`, `ata`, `dfu`, `modem-manager`,
`tpm`, `thunderbolt` and `flashrom` plugins; D-Bus activated, not resident; state on
`/data`. Two remotes: LVFS stable (can be disabled for air-gapped fleets) and an
`ironflock` remote whose metadata and `.cab` files are signed with an IronFlock key
(Jcat) and served from `dl/ironflockos/firmware/`, for vendor firmware that is not on LVFS
and for pinning what a fleet may install. The device-agent gets four RPCs over fwupd's
D-Bus API: `get_firmware_inventory` (`GetDevices`), `get_firmware_updates`
(`GetUpgrades`), `install_firmware_update` (`Install`, offline where the plugin needs a
reboot) and `get_firmware_history`. Inventory is reported with the device info so the
platform has fleet-wide firmware visibility; scheduling, maintenance windows and staged
roll-outs are platform features.

**Policy.** Firmware is never updated automatically. Lane 2 travels with OS releases and
is gated by the same health check as the slot switch. Lane 3 is an explicit platform
action inside a maintenance window, on stable power, with the result recorded. Firmware
of hardware that apps attach (sensor MCUs and the like) is an app concern through device
passthrough; fwupd's DFU plugin can be exposed to apps later.

### 3.11 Real-time kernel option

PREEMPT_RT is in mainline Linux since 6.12, so no out-of-tree patches are involved.
Debian 13 ships `linux-image-rt-amd64` and `linux-image-rt-arm64` (6.12 series) with
Debian security support. The `rt` kernel axis is a profile fragment (`profiles/kernel-rt`)
that swaps the kernel package and adds tuning; everything else in the image is identical.

| Target | RT kernel source | Status |
|--------|------------------|--------|
| `amd64-efi`, `arm64-efi` | Debian `linux-image-rt-<arch>` | Package swap; Phase 4b |
| `rpi-arm64` | Raspberry Pi kernel tree (`rpi-6.12.y`) built in CI with `CONFIG_PREEMPT_RT=y`, packaged as `linux-image-rpi-v8-rt` / `-2712-rt` into an IronFlock apt repo; Raspberry Pi OS ships no RT kernel | CI kernel build; follow-up to Phase 5 |
| `jetson-orin` | NVIDIA's RT configuration (`nvbuild.sh -r`, `-rt-tegra` suffix) built in CI from the pinned BSP | Phase 6 follow-up; CUDA on the RT kernel has open issues on JetPack 6.2.x, verify first |
| `nvidia` variant on x86 | NVIDIA's open kernel modules do not officially support PREEMPT_RT (only the `IGNORE_PREEMPT_RT_PRESENCE=1` workaround) | Not offered until NVIDIA supports it |

What a `-rt` image adds besides the kernel:

- `rt-tests` (`cyclictest`, `hwlatdetect`) for acceptance and field diagnosis.
- `ironflockos-rt-tuning`: a kernel command-line fragment (`isolcpus=`, `nohz_full=`,
  `rcu_nocbs=`, `irqaffinity=`, C-state limits such as `processor.max_cstate=1` and
  `intel_idle.max_cstate=0`, `nosoftlockup`), the `performance` governor, `irqbalance`
  kept off the isolated CPUs, transparent huge pages off. The CPU set comes from
  `/data/ironflockos/rt.conf`, a device setting the platform manages; the enroll step writes
  the resulting command line into the active boot slot (`grub.cfg` or `cmdline.txt`) so
  it survives an A/B switch.
- Guidance for containers: real-time workloads run with `--cap-add SYS_NICE`,
  `--ulimit rtprio=99` and `--cpuset-cpus` on the isolated CPUs. Docker's
  `--cpu-rt-runtime` needs `RT_GROUP_SCHED`, which does not coexist with PREEMPT_RT, so
  it is not used. This becomes a "real-time" profile in the IronFlock app templates.
- A separate `compatible` (`-rt`), because kernel modules differ. `-rt` images update only
  to `-rt` images; switching between `std` and `rt` is a reflash in 1.x.

Acceptance per target: `cyclictest -m -Sp99 -i200 -h400` for one hour under Docker load
on isolated CPUs, with the maximum latency recorded in `docs/targets/<target>.md` per
hardware class. QEMU only smoke-tests that the image boots; latency numbers come from
the hardware checklist.

## 4. Roadmap

Effort is in engineer-weeks for one engineer who knows the stack; treat as ±50%.
Phases 3, 4 and 4b can run in parallel with 5; 6 is independent after 2.
The phases are cut into work packages with acceptance criteria, estimates and
dependencies in [implementation-plan.md](implementation-plan.md); that is the list to work from.

### Phase 0: Foundations and hygiene (1 to 2 weeks)

Deliverables:
- Repo transferred to `IronFlock/ironflockos`, public; default branch `main`; rulesets
  applied; `IronFlock/ironflockos` (old, private) archived after harvesting its 64-bit RPi
  notes ([ADR-0002](adr/0002-repo-home-ironflock-flockos.md)).
- Secrets removed from the tree and from the public history where feasible: the VM
  password in `cubic/README.md`, root password hashes in the autoinstall files, the
  Buildroot `BR2_TARGET_GENERIC_ROOT_PASSWD`. The RAUC key pairs retired; `gs://reswarmos-certs`
  emptied; the committed key in the old ironflockos repo noted in its archive README.
- `.github/workflows/{ci,security,release}.yml` as thin callers that pass on an empty
  `just` skeleton (`lint`, `test`, `build` recipes exist and succeed); `VERSION` = `0.9.0`.
- `shell-gate.yml` contributed to `IronFlock/workflows`.
- `docs/` (this plan, audit, ADRs) merged; top-level README states the status.
- The last commit before deletion of the old trees is recorded: `82b9a03`.

Acceptance: a no-op PR goes green through `ci-ok` and `security / report`.

### Phase 1: `amd64-efi` base image with A/B (3 to 4 weeks)

Deliverables:
- `build/`, `profiles/base`, `targets/amd64-efi`, `overlay/` producing
  `ironflockos-amd64-efi-base-<v>.img.gz` and `.raucb` with `just build amd64-efi base`.
- GRUB A/B with RAUC `grub` backend; `systemd-repart` growth of `data`; `/data`
  redirections; `rauc status` healthy; `ironflockos-enroll.service` present but calling the
  current `ironflock-init` installer (full enroll comes in Phase 2).
- QEMU `image-test` in `ci.yml` including update to B and fallback to A.
- `fwupd` installed with its state on `/data`; the QEMU test runs a firmware inventory.
- Throwaway-key signing in PR builds; KMS key and CA created, release signing wired
  but releases still manual (`workflow_dispatch`).

Acceptance: a developer flashes the CI-built image onto a USB SSD, boots an x86 IPC, and
the device is reachable on the console; the QEMU A/B test passes on every PR.

### Phase 2: Provisioning, OS update client, release pipeline (3 to 4 weeks, cross-repo)

Deliverables:
- device-init: `bake` and `enroll`, os-release detection, offline tolerance (3.4).
- Image: `ironflock-init bake` in the build hook; `ironflockos-enroll` at first boot; agent
  preinstalled; first boot offline then online works.
- device-agent: manifest-based OS update client, persistent download, error returns,
  `perform_os_update`, post-connect `mark-good`, `ironflockos` layout (3.5).
- device-agent: firmware inventory and update RPCs over fwupd's D-Bus API (3.10); the
  platform shows firmware versions per device.
- `release.yml` complete: stage, e2e (enroll + N-1→N update), promote, signed
  `manifest.json`, GitHub Release, tag. First tagged release `v1.0.0` of `amd64-efi/base`.
- FlockFlasher: new catalog with signature verification, variant selection, `IRONFLOCKOS`
  label targeting (3.6). Legacy catalog frozen.

Acceptance: from FlockFlasher, flash the released image onto a disk, boot the IPC, see
the device online in IronFlock within two minutes, run an app; then bump `VERSION`,
merge, and update the same device from the platform with rollback verified once by
sabotaging the new slot.

### Phase 3: Installer USB (1 to 2 weeks)

Deliverables: `profiles/installer`, `ironflockos-installer` (shell or small Go program),
`installer.conf` rules, embedded payload selection, `efibootmgr` registration,
unattended and interactive modes; QEMU test that installs from a virtual USB to a
virtual NVMe and boots the result; FlockFlasher treats it as a normal image.

Acceptance: a sealed IPC with one NVMe is installed from a USB stick prepared by
FlockFlasher without a keyboard when `installer.conf` says `confirm=no`.

### Phase 4: NVIDIA GPU variant on amd64 (1 to 2 weeks)

Deliverables: `profiles/nvidia` (3.7), `compatible=ironflockos-amd64-efi-nvidia`,
installer payload option, documentation of supported GPU generations (Turing and newer
with the open kernel modules), manual acceptance checklist on a GPU host.

Acceptance: `nvidia-smi` inside a container through Docker's `nvidia` runtime on a
real GPU host; A/B update of the nvidia variant keeps the module working.

### Phase 4b: Real-time kernel option on EFI targets (1 week)

Deliverables: `profiles/kernel-rt` (Debian `linux-image-rt-<arch>`), `-rt` images for
`amd64-efi` and `arm64-efi` `base`, `rt-tests` and the tuning profile with the
platform-managed CPU set (3.11), QEMU boot smoke test, hardware latency checklist,
installer payload option, release matrix extended.

Acceptance: an x86 IPC runs the `-rt` image, `uname -v` shows `PREEMPT_RT`, `cyclictest`
on isolated CPUs stays under the figure agreed for that hardware class for one hour
under Docker load; an A/B update between two `-rt` releases works.

### Phase 5: Raspberry Pi arm64 (3 to 4 weeks)

Deliverables: `targets/rpi-arm64`, tryboot A/B with RAUC `custom` backend and boot-slot
groups, `cmdline.txt` post-install hook, `rpi-eeprom` handling, support matrix (Pi 4,
Pi 5, CM4, CM5 first class; Pi 3, Zero 2 W boot without A/B), hardware test checklist,
FlockFlasher board entries, release matrix extended. EEPROM firmware pinned in the image
and staged by a RAUC post-install hook (3.10).

Follow-up (about 2 weeks, once the standard target is stable): the RT kernel built from
the Raspberry Pi tree in CI and published as `-rt` images (3.11).

Acceptance: Pi 4 and Pi 5 flashed from FlockFlasher enroll and update N→N+1 with
rollback; a Pi 3 boots and enrolls.

### Phase 6: Jetson Orin (5 to 7 weeks)

Deliverables: `targets/jetson-orin` on L4T r36.x (or JetPack 7.x if its Orin support is
confirmed at phase start; NVIDIA staff already point AGX Orin users at r39), mmdebstrap
Ubuntu rootfs + `apply_binaries.sh` + overlay, `ROOTFS_AB=1` layout with `data` and
`IRONFLOCKOS` partitions, RAUC `custom` backend over `nvbootctrl`, Orin Nano devkit SD
image, Orin NX/AGX flash package and documented host-side flashing, GPU-in-container
check (`nvidia-container-toolkit` is part of L4T; `--runtime nvidia`), bootloader (QSPI)
capsule generated from the BSP and staged by a RAUC hook (3.10), release matrix extended.

Follow-up: the RT kernel from NVIDIA's configuration (3.11), offered only after CUDA on
the RT kernel is verified on the chosen JetPack release.

Licence: Jetson Linux is under the NVIDIA Driver License Agreement. It allows
redistributing NVIDIA's binaries unchanged for use with an open source kernel, with
the Agreement given to every recipient. The
[licence review](jetson-licence-review.md) sets how IronFlockOS ships Jetson images:

- NVIDIA's packages stay unchanged in the image, and the Agreement goes next to every
  Jetson file.
- NVIDIA's GPL and FreeRTOS sources are mirrored with each release.
- The QSPI capsules are NVIDIA's own where NVIDIA ships them.
- Users get a flash kit that fetches the BSP from NVIDIA, instead of a published flash
  package.
- Images that NVIDIA's tools make from the BSP are published only if legal accepts
  them.

IronFlock's legal check signs off before the first Jetson release (ADR-0008, WP-6.8).

Acceptance: Orin Nano devkit flashed from FlockFlasher (or, if legal does not accept
the SD image, from a host with the flash kit) enrolls and runs a CUDA container; an
Orin NX on NVMe is flashed from a Linux host with the flash kit, enrolls, and updates
N→N+1 with rollback.

### Phase 7: Generic arm64 EFI, decommission, documentation (1 to 2 weeks)

Deliverables: `targets/arm64-efi` (QEMU `virt` tested), `arm64-efi` installer payload,
migration guide for ReswarmOS devices (reflash), `gs://reswarmos` set read-only with a
sunset date, docs refreshed (`docs/targets/*.md`, README rewritten), `legacy` code paths
in flasher and agent flagged for removal after the sunset date.

Acceptance: an arm64 VM boots the image and enrolls; all docs reviewed.

## 5. Cross-repo change list

| Repo | Change | Phase |
|------|--------|-------|
| **workflows** | `shell-gate.yml` (lint/unit/build via `just`, shellcheck/shfmt/yamllint from `tools.lock`) | 0 |
| **workflows** | `security.yml` `rootfs-recipe` input (trivy rootfs scan + SBOM of a built tree) | 1 |
| **device-init** | `bake`, `enroll`, os-release detection, offline tolerance, `docker: preinstalled`, e2e target on the image | 2 |
| **device-agent** | manifest-based OS updates, persistent download + sha256, honest errors, `perform_os_update`, post-connect `mark-good`, slot status in device info, `ironflockos` layout, tolerant os-release parsing | 2 |
| **device-agent** | firmware inventory, available updates, install and history over fwupd's D-Bus API; boot-firmware versions (EEPROM, UEFI, QSPI) in device info | 2 |
| **flasher** | signed `dl/ironflockos/manifest.json`, variant choice, `IRONFLOCKOS` label targeting, Windows mount path, drop ISO repack, `.img.xz`, IronFlockOS branding | 2 (installer: 3) |
| **GCP** | KMS keys `ironflockos-rauc-ca` (one-shot) and `ironflockos-rauc-signer`, WIF SA `ironflockos-release@record-1283`, bucket prefixes `ironflockos/` and `staging/ironflockos/`, `gs://reswarmos` read-only, `gs://reswarmos-certs` emptied | 0 to 2 |
| **platform (studio/backend)** | show OS image id/version and slot status, "reflash required" for legacy images, OS update action wired to `perform_os_update` | 2 |
| **platform (studio/backend)** | firmware inventory and update actions with maintenance windows and staged roll-outs; real-time CPU set as a device setting; `-rt` image choice in FlockFlasher and the platform | 2, 4b |
| **ironflock-templates** | a "real-time" app profile (`SYS_NICE`, `rtprio` ulimit, cpuset) | 4b |
| **website/docs** | IronFlockOS install guides per target, replacing the Reswarm docs linked from the old catalog | 2, 5, 6 |

## 6. First two weeks (concrete next steps)

1. Transfer the repo to `IronFlock/ironflockos` (public), rename `master` to `main`, apply
   the standard rulesets, create the `release` environment.
2. Remove the plaintext VM password and the root hashes from the tree; rotate the VM
   password; empty `gs://reswarmos-certs`; archive the old `IronFlock/ironflockos` with a
   README noting the committed key.
3. Delete `buildroot/`, `cubic/`, `ironflockos-vm-setup.md` (last in `82b9a03`)
   in the same PR that adds the `just` skeleton and the three workflow callers (they
   cannot lint the old trees anyway).
4. Open the `shell-gate.yml` PR in `IronFlock/workflows`.
5. Create the KMS keys and the IronFlockOS root CA certificate; document the PKCS#11 signing
   recipe in `docs/signing.md`; prove `rauc bundle --key 'pkcs11:...'` from a workflow.
6. Start Phase 1 with `targets/amd64-efi` and the QEMU test harness; the first PR that
   boots in QEMU is the milestone.

## 7. Risks and open questions

| Risk | Mitigation |
|------|------------|
| Raspberry Pi tryboot + RAUC is not an upstream RAUC backend; the firmware feature is only partly documented | Follow the Bootlin/Oniro implementations, pin firmware versions, keep U-Boot as the documented fallback |
| Jetson rootfs A/B has reported edge cases (retry counter only decrements on warm reboot; redundancy triggers only when the slot fails to mount) | The agent's health gate plus a watchdog-driven warm reboot on failed enroll; test on r36.4.x before committing |
| JetPack generation drift (r36 Ubuntu 22.04 vs r38 Ubuntu 24.04) | Decide at Phase 6 start; the pipeline is distro-agnostic |
| NVIDIA's Jetson licence is proprietary and revocable: redistribution only of unchanged binaries with the Agreement, an indemnity for products that use the software, no Critical Applications | [Licence review](jetson-licence-review.md): NVIDIA's packages and capsules shipped unchanged with the Agreement, sources mirrored, BSP-made images only after legal accepts them (flash kit otherwise); legal signs off before the first Jetson release (WP-6.8) |
| Runner disk (14 GB) and no GPU/arm hardware in CI | Build on `/mnt`, sparse images; hardware acceptance is a documented manual gate per phase; consider one self-hosted arm64 runner with a Pi 5 later |
| NVIDIA driver vs kernel ABI | Module built per release against the pinned kernel; `nvidia` variant has its own `compatible` |
| `.flock` on a FAT partition is readable until enrollment | Enroll shreds it; document that an unenrolled flashed medium holds secrets |
| device-init and device-agent changes are on other teams' timelines | Phase 1 is independent; Phase 2 is the cross-repo milestone and is listed per repo in section 5 |
| Public repo with release signing | No key material in the repo or runners (WIF + KMS); dry runs use ephemeral keys; rulesets block unreviewed changes to workflows |
| Boot-firmware writes are not redundant everywhere (Pi EEPROM, PC UEFI capsules); power loss mid-write can brick a device | Lane 2 only inside platform-controlled maintenance windows, never automatic; Jetson's bootloader A/B is preferred; the Pi SD-card recovery procedure is documented; no capsule on hardware without a vendor fallback |
| Most industrial PC vendors do not publish UEFI firmware to LVFS | Package vendor capsules into the IronFlock-signed fwupd remote where the vendor provides files; otherwise the target docs state "no in-field BIOS update" for that board |
| NVIDIA's x86 modules do not officially support PREEMPT_RT; CUDA on Jetson's RT kernel has open issues | `nvidia-rt` is not offered on x86; Jetson `-rt` only after CUDA is verified on the chosen release; `-rt` has its own `compatible` so it never mixes with `std` |
| RT latency depends on firmware settings (C-states, SMIs) and on the exact board | Per-hardware-class latency figures published in the target docs; the tuning profile is a device setting, not a global default |

Open questions to settle before Phase 2 (1, 2, 4 and 5 settled 2026-11-05 in
[ADR-0009](adr/0009-phase-2-decisions-hostname-channels-firmware.md)):

1. Should `enroll` set the hostname from the `.flock` `name` by default on IronFlockOS (the
   legacy image did) while device-init on third-party OSes leaves it alone?
   **Settled:** yes, by default; `hostname-from-flock=no` in `enroll.conf` keeps it.
2. Is there a platform-side notion of OS release channels (production/test) that the
   manifest should mirror, or is a single channel enough for 1.x?
   **Settled:** two channels, production and test, as in the device-agent's manifest.
3. Who owns the GPU acceptance hardware and the Orin modules for Phase 4 and 6? Open.
4. Which firmware lane does the platform expose first: boot firmware bundled with OS
   releases only, or component firmware through fwupd as well?
   **Settled:** boot firmware with OS releases, and the fwupd inventory read-only;
   fwupd updates later.
5. Who defines the real-time tuning (isolated CPUs, IRQ affinity) per device: an image
   default, a device setting in the platform, or the app that needs it?
   **Settled by WP-4b.1:** a device setting in the platform (`/data/ironflockos/rt.conf`).

## 8. Later hardening (after this program)

Read-only root with dm-verity from the RAUC `verity` hash tree, Secure Boot on x86 with
IronFlock keys and signed UKIs (beyond ADR-0011's Debian chain, which only makes Secure
Boot on machines boot) (systemd-boot + RAUC `efi` backend becomes attractive
then), TPM-bound device keys, RAUC streaming installs, delta updates (RAUC adaptive
updates), and a self-hosted arm64 runner with real Raspberry Pi hardware in the loop.

## Appendix A: Glossary

- **Target**: a hardware class with one boot method and partition layout.
- **Variant**: a software profile on a target (`base`, `nvidia`, `installer`).
- **Slot**: one of the two root filesystems (A/B) RAUC switches between.
- **`.flock`**: the per-device JSON configuration file issued by IronFlock (formerly `.reswarm`).
- **Harness**: the shared reusable workflows in `IronFlock/workflows`.
- **Capsule**: a UEFI firmware update payload that the firmware applies at boot (PC BIOS, Jetson QSPI).
- **LVFS**: Linux Vendor Firmware Service, the public firmware repository `fwupd` uses.
- **PREEMPT_RT**: the real-time preemption model of the Linux kernel, mainline since 6.12.

## Appendix B: References

- RAUC documentation: https://rauc.readthedocs.io (GRUB and custom bootloader backends, PKCS#11 signing, verity bundles)
- Bootlin, "Safe updates using RAUC on Raspberry Pi 5": https://bootlin.com/?p=19769
- Raspberry Pi tryboot and `autoboot.txt`: https://www.raspberrypi.com/documentation/computers/config_txt.html#autoboot-txt
- NVIDIA Jetson Linux r36 "Update and Redundancy": https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/SD/Bootloader/UpdateAndRedundancy.html
- mmdebstrap: https://gitlab.mister-muffin.de/josch/mmdebstrap
- genimage: https://github.com/pengutronix/genimage
- Google Cloud KMS PKCS#11 library: https://github.com/GoogleCloudPlatform/kms-integrations
- GitHub arm64 hosted runners: https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/
- IronFlock CI harness: https://github.com/IronFlock/workflows
- fwupd and LVFS: https://fwupd.org and https://fwupd.github.io/libfwupdplugin/
- Raspberry Pi EEPROM updates: https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-boot-eeprom
- Jetson bootloader capsule updates (r36 "Update and Redundancy", see above); capsule generation with `l4t_generate_soc_capsule.sh` in the BSP
- Debian real-time kernels: https://packages.debian.org/trixie/linux-image-rt-amd64 and https://packages.debian.org/trixie/linux-image-rt-arm64
