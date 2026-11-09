# ADR-0007: RAUC stays the OS updater; firmware travels in three lanes

Status: accepted, 2026-11-04.

## Context

Before Phase 1 fixes the update stack, the question was raised whether RAUC is the
right mechanism for IronFlockOS, whether SWUpdate would be a better fit, and how firmware
for hardware components is handled. What matters for IronFlockOS:

- IronFlock already owns the fleet-management channel (the device-agent). The device
  side needs an installer with a clean local API, not an updater that brings a server.
- Three unrelated boot mechanisms must be served with one bundle format and one signing
  scheme: GRUB on UEFI PCs, the Raspberry Pi firmware's tryboot, NVIDIA's UEFI with
  `nvbootctrl` on Jetson.
- The agent's RAUC coupling is small: `src/system/rauc.go`, 186 lines, one call site, in
  a 56,500-line code base.
- Firmware comes in three kinds: blobs the kernel loads at runtime, boot firmware the OS
  release depends on, and component firmware (SSDs, NICs, modems, PC UEFI) with its own
  vendor channels.

## Alternatives considered (figures as of 2026-11-04)

| Mechanism | Assessment |
|-----------|------------|
| SWUpdate | Closest peer. 1,898 GitHub stars, 307 commits in the last year of which half by the sole maintainer, strict May/December releases, in Debian 13 (2024.12.1) with security support. No D-Bus API and no Go client: the agent would use the C-struct socket IPC, the `swupdate-client` binary, or the loopback web server. Bootloader interfaces are U-Boot, GRUB, EFI Boot Guard and "none", chosen at compile time; Pi tryboot and Jetson would be post-install scripts or a C patch rather than RAUC's four-verb `custom` contract. Comparable delta updates (zchunk). Agent-side switch cost about one engineer-week; the real cost is the two custom bootloader integrations. |
| Mender | Strong Debian story (mender-convert) but its value is the server, which duplicates the platform; delta updates are a paid tier; U-Boot on Pi. |
| OSTree (Endless, Apertis, Torizon style) | Best bandwidth and more than two deployments, at the price of a non-standard filesystem layout and per-platform bootloader integration; exotic on Jetson. |
| systemd-sysupdate with systemd-boot and UKIs | Leanest stack for UEFI machines and what mkosi produces, but it needs systemd-boot, so it covers neither the Pi firmware nor NVIDIA's boot chain. Kept in view for the EFI targets (ADR-0005). |
| bootc / image mode | OS as an OCI image; Debian support experimental, no Pi or Jetson. Watch. |
| apt unattended upgrades | No atomicity or rollback; wrong paradigm for an appliance. |
| RAUC | 1,274 stars, 455 commits in the last year from a broad contributor base (15 in v1.15), Pengutronix behind it, LGPL, in Debian 13 (1.13). D-Bus API already used by the agent. `custom` bootloader backend with a documented script contract. CMS signing with PKCS#11. Verity bundles with HTTPS streaming (1.7) and adaptive block-level updates (1.8), so whole-slot bundles do not mean whole-slot downloads. Fixed slot sizes and no built-in scheduling are acceptable given the agent. |

## Decision

1. RAUC remains the OS update mechanism for all targets. Adaptive (block-hash-index)
   updates over streamed `verity` bundles are a Phase 2 goal, not a later nicety; the
   Debian build's streaming support is verified at Phase 1 start and the 1.15 package
   taken if trixie's 1.13 lacks it.
2. Firmware is handled in three lanes (master plan 3.10):
   - runtime-loaded firmware and microcode are rootfs content and ride in every bundle;
   - boot firmware an OS release depends on (Pi EEPROM, Jetson QSPI capsule, vendor UEFI
     capsules) ships inside the RAUC bundle and is staged by a post-install hook, applied
     on the slot-switch reboot, gated by the same health check;
   - component firmware goes through `fwupd`, driven by the agent over D-Bus, with
     metadata from LVFS or an IronFlock-signed remote; the platform schedules it.
3. The real-time kernel option does not change the mechanism: `-rt` images are a kernel
   axis with their own `compatible` string and update through the same path.

## When to revisit

- Raspberry Pi and Jetson leave the target list and only UEFI machines remain:
  systemd-sysupdate with systemd-boot and UKIs becomes the leaner stack.
- Updates become frequent over metered links: OSTree-style file deltas beat RAUC's
  block-level adaptive updates.
- SWUpdate gains a first-class pluggable bootloader contract and a language-neutral API,
  or the team acquires SWUpdate expertise or an EFI Boot Guard requirement.
