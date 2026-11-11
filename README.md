<p align="center">
  <a href="https://www.ironflock.com">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/assets/ironflock-white.svg" />
      <img alt="IronFlock" src="docs/assets/ironflock.svg" width="160" />
    </picture>
  </a>
</p>

# IronFlockOS

IronFlockOS is the operating system for industrial edge devices managed with IronFlock. Its
aim is a trusted, hardened OS that updates over the air reliably and without a site
visit, wherever a device runs: an industrial PC in a machine cabinet, a Raspberry Pi on
the shop floor, a GPU host, a plant network without internet access, or a virtual
machine.

IronFlockOS is a Debian-based appliance OS. It runs the
[IronFlock device-agent](https://github.com/IronFlock/device-agent) and Docker, and
nothing else. Applications run as containers that IronFlock deploys. IronFlockOS is the
small, signed base underneath them, and each update replaces its whole root filesystem,
kernel included.

## Purpose

- **Part of IronFlock's over-the-air updates.** An OS update is started from IronFlock
  and installed by the device-agent, the same agent that runs the apps.
  [RAUC](https://rauc.io) writes the new system into the inactive one of two slots. The
  device boots it once and keeps it only if the agent reaches IronFlock from it;
  otherwise the device falls back to the previous slot by itself. Data, Docker's images
  and containers, and the device's enrollment stay across updates.
- **Trusted.** A device installs only update bundles signed with the IronFlockOS key, which
  never leaves a Cloud KMS HSM, and finds them through a signed catalog. Every release is
  built and signed in GitHub Actions and has SLSA provenance
  ([Supply chain and security](#supply-chain-and-security)).
- **Hardened.** An image has no user accounts and no passwords, and SSH refuses
  passwords and root. The EFI targets boot with Secure Boot on. A verified read-only root
  and Secure Boot with IronFlock's own keys are planned.
- **Reliable on site.** The first boot needs no network: the device enrolls from its
  `.flock` file and connects once the network is there. Devices behind an IronFlock
  appliance get the catalog and their updates from the appliance, without internet
  access. Each release goes to a test channel before production.
- **One OS for many deployments.** x86 PCs and industrial PCs, with an installer stick
  for those whose disk cannot be taken out; arm64 machines; Raspberry Pi 4 and 5; GPU
  hosts whose containers use the GPU; PREEMPT_RT images for real-time workloads; Compute
  Engine images for IronFlock's virtual devices. One version number covers every image
  of a release. Jetson Orin is in progress.

## Status

IronFlockOS is not at 1.0 yet. The [latest release](https://github.com/IronFlock/ironflockos/releases/latest)
has images for three targets. On every pull request, CI boots each EFI image in QEMU and
tests the first boot, enrollment, an A/B update and the fallback. No target has passed
its hardware acceptance yet; `v1.0.0` follows the first one, on an x86 industrial PC.
The status of each work package is in [docs/implementation-plan.md](docs/implementation-plan.md).

## Targets and images

| Target | Hardware | Boot and A/B | Images in a release |
| ------ | -------- | ------------ | ------------------- |
| `amd64-efi` | x86-64 PCs and industrial PCs with UEFI | shim, GRUB, RAUC | `base`, `base-rt`, `nvidia`, `installer` |
| `arm64-efi` | arm64 machines with UEFI (SystemReady boards, VMs) | shim, GRUB, RAUC | `base`, `base-rt`, `installer` |
| `rpi-arm64` | Raspberry Pi 4, 400, 5, CM4, CM5 | Pi firmware tryboot, RAUC | `base` |
| `jetson-orin` | NVIDIA Jetson Orin | NVIDIA UEFI and `nvbootctrl`, RAUC | none yet: the root tree and layout are done, the A/B backend and images are not |

- **`base`**: Debian 13 with systemd, NetworkManager, OpenSSH, Docker CE, RAUC, fwupd,
  the device-agent and `ironflock` (`/usr/bin/ironflock`).
- **`base-rt`**: `base` with Debian's PREEMPT_RT kernel and a tuning service. EFI
  targets only.
- **`nvidia`**: `base` with NVIDIA's open kernel modules, driver and container toolkit,
  for GPUs in containers. With Secure Boot on, the kernel refuses the modules: the
  device runs, but the GPU needs Secure Boot off.
- **`installer`**: a USB stick for PCs that writes one of its target's images to an
  internal disk. It carries every image of its target.

A Raspberry Pi 4 needs an EEPROM from 2020-10 or later. The Pi 3 and Zero 2 W are not
supported: their firmware cannot boot from GPT or read `autoboot.txt`. Jetson uses Ubuntu 24.04, which NVIDIA's Jetson Linux needs
([ADR-0008](docs/adr/0008-jetson-orin-bsp-jetpack-7.md)). Target notes are in
[docs/targets/](docs/targets/).

## Installing

Install IronFlockOS with [FlockFlasher](https://github.com/IronFlock/flasher). It lists the
images of the production channel, writes the chosen one to an SD card, USB stick or
disk, and puts the device's `.flock` file on it. You get the `.flock` file from IronFlock
when you add the device there. On the first boot the device enrolls with it: it gets its
hostname, an SSH user and its agent identity. An image has no user account of its own.

For a PC, write the `installer` image to a USB stick with FlockFlasher and boot the PC
from it. The installer asks on the console, writes the chosen image to the largest
internal disk, copies the `.flock` file to it, and powers off
([docs/targets/amd64-efi.md](docs/targets/amd64-efi.md)).

Updates come from IronFlock. The device-agent downloads the update bundle of its image,
RAUC writes it into the inactive slot, and the device boots it. A release goes to the
`test` channel first, and production moves to it after it has run on test devices.

Every file of a release is at `https://instance-registry.ironflock.com/dl/ironflockos/<version>/`,
for example `.../dl/ironflockos/0.16.0/ironflockos-amd64-efi-base-0.16.0.img.gz`. For each image there is the disk image (`.img.gz`), the update bundle (`.raucb`, none for
the installer), the package list (`.packages.tsv`) and `.os-release`. `SHA256SUMS`,
the SBOMs and the signed catalog are attached to each
[GitHub Release](https://github.com/IronFlock/ironflockos/releases).

## Supply chain and security

- **Signed update bundles.** The bundle signing key is in a Cloud KMS HSM. Release
  images trust only the IronFlockOS root CA ([pki/](pki/README.md), with fingerprints) and
  refuse any other bundle. Pull-request and local builds sign with throwaway keys
  that no release image accepts ([docs/signing.md](docs/signing.md)).
- **Signed catalog.** The device-agent and FlockFlasher read image and bundle URLs,
  sizes and SHA-256 sums from the catalog `dl/ironflockos/manifest.json`, which is signed
  with an Ed25519 key in Cloud KMS. To check it, run this in a checkout with Go:

  ```sh
  curl -fsSO https://instance-registry.ironflock.com/dl/ironflockos/manifest.json
  go -C tools/catalog run . verify -pubkey "$PWD/pki/ironflockos-catalog.pub" "$PWD/manifest.json"
  ```

- **SLSA Build Level 3.** Every disk image and update bundle of a release after 0.11.0
  has [SLSA v1.0](https://slsa.dev/spec/v1.0/levels) build provenance. It is built on
  GitHub-hosted runners, with no build cache shared with other builds. A separate job
  then attests it with
  [GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
  (Sigstore). That job is a reusable workflow in
  [IronFlock/workflows](https://github.com/IronFlock/workflows) and runs none of this
  repository's code, so this repository's build steps cannot reach the identity that
  signs the provenance. To check a file with the GitHub CLI:

  ```sh
  gh attestation verify ironflockos-amd64-efi-base-<version>.img.gz --repo IronFlock/ironflockos \
    --signer-workflow IronFlock/workflows/.github/workflows/attest-provenance.yml --source-ref refs/heads/main
  ```

  Releases up to 0.12.0 were built when this repository was named `IronFlock/ironflockos`,
  and their provenance records that name. Check them with `--repo IronFlock/ironflockos`.
  Releases up to 0.11.0 meet Build Level 2: the job that attested them also ran this
  repository's bundle-signing script. Check them with
  `--signer-workflow IronFlock/ironflockos/.github/workflows/release.yml`.
- **SBOMs and vulnerability scans.** Each release attaches a CycloneDX SBOM for each
  image except the installers. A Trivy scan of the images' root filesystems is part of
  the required `security / report` check, which fails on critical and high
  vulnerabilities that have a fix. The scan runs again every week. Each accepted finding
  has a reason and an expiry date.
- **Secure Boot.** The EFI targets boot Debian's signed boot chain (Microsoft-signed
  shim, Debian's GRUB and kernel), so they boot on PCs that have Secure Boot on, as most
  PCs ship. This is for convenience, not tamper resistance. GRUB's configuration, the
  initramfs and the root filesystem are not verified
  ([ADR-0011](docs/adr/0011-secure-boot-with-debians-signed-boot-chain.md)).
- **Not yet.** The root filesystem is writable and not verified (dm-verity). Secure Boot
  with IronFlock's own keys, measured boot and TPM-bound device keys are also not done.
  All of these are planned as later hardening
  ([master plan, section 8](docs/master-plan.md#8-later-hardening-after-this-program)).
- **Reproducibility.** File times and filesystem IDs come from the commit, and Docker
  and NVIDIA packages are pinned. The Debian archive is not pinned to a snapshot, so two
  builds of the same commit on different days can contain different package versions.
  `.packages.tsv` lists the versions in each image.

Report vulnerabilities privately to [security@ironflock.com](mailto:security@ironflock.com),
as described in the [IronFlock security policy](https://github.com/IronFlock/.github/blob/main/SECURITY.md).

## Working in this repository

```sh
just lint                       static checks as CI runs them
just test                       unit tests (bats, and go test for tools/)
just build amd64-efi base       one image into out/; add rt for the -rt kernel
just qemu-test amd64-efi base   boot it in QEMU and run the image tests
```

A build runs in a pinned Debian 13 container and needs only Docker and `just`; `just qemu-test`
needs QEMU and OVMF. A local build signs with throwaway keys, so its image accepts only
bundles from the same build. CI is the build of record
([docs/build.md](docs/build.md), [docs/testing.md](docs/testing.md)).

Pull requests into `main` are squash-merged and need the checks `ci-ok` and
`security / report`. CI builds every image and tests the EFI images and installers in
QEMU. A release is a version bump: `just release-patch` (or `release-minor`,
`release-major`) opens the pull request `release ironflockos v<version>`, whose CI also
builds the release images and runs every test. Its merge runs `release.yml`, which
reuses those images when it can (otherwise it builds them and boots its image of
`amd64-efi base` in QEMU), signs the bundles in Cloud KMS, checks each against the
keyring in its image (without installing it), publishes the images and the signed
catalog, and sets the tag last ([docs/release.md](docs/release.md), ADR-0018,
ADR-0019).

## Documentation

- [docs/build.md](docs/build.md): how an image is built, the disk layout, boot and A/B
- [docs/release.md](docs/release.md): the release run, the channels, the catalog
- [docs/signing.md](docs/signing.md): the RAUC PKI in Cloud KMS
- [docs/testing.md](docs/testing.md): unit tests, QEMU tests, the hardware checklist
- [docs/targets/](docs/targets/): notes for each target
- [docs/master-plan.md](docs/master-plan.md): goals, architecture, roadmap
- [docs/implementation-plan.md](docs/implementation-plan.md): work packages and their status
- [docs/adr/](docs/adr/): architecture decision records

## License

Copyright 2026 IronFlock GmbH. This repository is licensed under the Apache License 2.0,
see [license.md](license.md).

An image is a collection of separate programs, each under its own licence, which
`/usr/share/doc/<package>/copyright` in the image names. The source code of every package
in a release's images is on the download server: `SOURCES` next to the images,
`https://instance-registry.ironflock.com/dl/ironflockos/<version>/SOURCES`, lists it
([docs/release.md](docs/release.md#source-code)). Releases up to 0.11.0 have no `SOURCES`.
