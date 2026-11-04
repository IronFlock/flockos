# ADR-0001: One Debian-based image pipeline for all targets

Status: accepted, 2026-11-04.

## Context

The repo has two builders: Buildroot (32-bit Raspberry Pi only, pinned to early 2022,
1 to 2 hours per build, Jetson and x86 configs unbuildable) and Cubic (Ubuntu 20.04
GUI wizard, not automatable). The targets to support are amd64 and arm64 edge PCs,
Raspberry Pi, NVIDIA GPU hosts and Jetson Orin. The device setup tool `ironflock-init`
supports "Debian or Ubuntu-based systems with systemd" and uses apt. NVIDIA drivers,
`nvidia-container-toolkit` and Jetson Linux (L4T) are apt packages on Debian/Ubuntu.
Builds must run in GitHub Actions.

Alternatives considered:

- **Buildroot for Pi, Debian elsewhere**: two toolchains; `ironflock-init` cannot run
  on a Buildroot root (no apt); Jetson needs L4T anyway.
- **Yocto with meta-raspberrypi, meta-tegra, meta-rauc**: most flexible, but hours-long
  builds that need an sstate cache outside GitHub-hosted runners, and the highest
  ramp-up cost for a small team.

## Decision

All FlockOS images are built from Debian stable (Ubuntu 22.04 where Jetson Linux
requires it) with one headless pipeline. The image reuses `ironflock-init` for host
setup at build time (`bake`) and first boot (`enroll`). Buildroot and Cubic are removed.

The condition attached by the owner, that installer images able to install a bootable
system onto another disk remain possible, is met by the `installer` variant described
in [ADR-0004](0004-raw-image-plus-installer-usb.md).

## Consequences

- Image size grows from about 400 MB (Buildroot) to roughly 1.5 to 2 GB per slot;
  acceptable for 16 GB media and above.
- Security updates for the base come from Debian; they reach devices as new FlockOS
  releases, never as in-place apt upgrades.
- 32-bit ARM boards are dropped.
- Build time per image falls to 10 to 20 minutes, which makes PR-time boot tests
  feasible.
