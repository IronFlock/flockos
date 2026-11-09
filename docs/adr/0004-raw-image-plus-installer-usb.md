# ADR-0004: Raw disk images everywhere, plus a IronFlockOS installer USB for PCs

Status: accepted, 2026-11-04.

## Context

FlockFlasher writes raw `.img.gz` files to removable media and copies the `.flock`
configuration onto the first partition. For PCs it also repacks installer ISOs with
xorriso, assuming the Ubuntu 20.04 isolinux layout that newer ISOs no longer have. Many
edge PCs have a single sealed internal disk, so a plain raw image is not enough: an
installer that writes to another disk is required.

Alternatives considered:

- **Raw image only**: users would dd to the internal disk themselves; impractical for
  sealed IPCs.
- **Debian/Ubuntu autoinstall or preseed ISO built headlessly**: closest to Cubic, but
  the resulting system is "installed" rather than image-identical, the flasher's ISO
  repack would need a GRUB-only rewrite, and the A/B layout has to be recreated by the
  installer logic instead of being the image.

## Decision

Every artefact is a raw disk image. For PCs there is an `installer` variant: a IronFlockOS
image whose boot runs `flockos-installer` instead of the agent. It carries the target
image as a payload, picks the internal disk by rule or on the console, writes the
payload, transfers the `.flock` file and `installer.conf`, registers the EFI boot entry
and powers off. FlockFlasher treats the installer like any other image. The ISO repack
path in FlockFlasher is retired.

## Consequences

- One flashing code path in FlockFlasher; no ISO tooling, no isolinux assumptions.
- The installed system is bit-identical to a directly flashed one, so one QEMU test
  covers both.
- The installer image is about twice the size of the base image (it embeds a payload).
- Unattended installs need an `installer.conf` on the stick; FlockFlasher can write it
  next to the `.flock` file.
