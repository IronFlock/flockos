# ADR-0005: Build with mmdebstrap and genimage behind a just/shell framework

Status: proposed, 2026-11-04 (to be confirmed by the first Phase 1 pull request).

## Context

[ADR-0001](0001-debian-based-image-for-all-targets.md) requires a headless Debian image
builder that runs on GitHub-hosted runners, cross-builds arm64 when no native runner is
used, assembles different partition layouts (GPT with ESP, Raspberry Pi FAT boot
partitions, Jetson rootfs tarballs for NVIDIA's flashing tools) and stays small enough
for one maintainer.

Alternatives considered:

- **mkosi**: excellent for UEFI x86/arm64 with systemd-repart, UKIs and verity, less
  natural for Raspberry Pi firmware partitions and Jetson flash packages; adds a Python
  tool with its own release cadence.
- **debos**: YAML recipes over debootstrap with fakemachine; proven for ARM boards, but
  fakemachine adds a virtualisation layer that is awkward on hosted runners, and the
  recipe language is less flexible than shell for the per-target hooks here.
- **pi-gen / live-build**: single-vendor or ISO-centric; not a fit for the matrix.

## Decision

- `mmdebstrap --mode=unshare` builds each rootfs unprivileged and reproducibly
  (`SOURCE_DATE_EPOCH`), cross-arch via `qemu-user-static` when needed, with hooks for
  the overlay and `ironflock-init bake`.
- `genimage` assembles the partition images into the disk image from
  `targets/<target>/genimage.cfg` (the team already knows genimage from Buildroot).
- `systemd-repart` grows the `data` partition on first boot.
- A `Justfile` exposes `lint`, `test`, `build TARGET VARIANT`, `bundle`, `qemu-test`
  and the harness release recipes; `build/*.sh` holds the logic, tested with `bats`.
- Jetson uses the same rootfs step and hands the tarball to NVIDIA's
  `apply_binaries.sh`, `jetson-disk-image-creator.sh` and `l4t_initrd_flash.sh`.

## Consequences

- No new DSL; the tooling is Debian packages available on `ubuntu-24.04` runners.
- Partition sizes are fixed in `genimage.cfg` per target and variant; changing them is
  a new image, never an in-place migration.
- If mkosi's UEFI features (UKIs, verity, systemd-boot) become wanted for the later
  hardening work, the `amd64-efi`/`arm64-efi` targets can switch to mkosi without
  affecting Raspberry Pi or Jetson.
