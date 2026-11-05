# ADR-0008: Jetson Orin on Jetson Linux r39.2.1 (JetPack 7.2.1), Ubuntu 24.04

Status: proposed, 2026-11-05 (WP-6.1). Needs the owner's acceptance before WP-6.2.

## Context

The master plan (sections 3.7 and Phase 6) put `jetson-orin` on Jetson Linux r36.x
(JetPack 6, Ubuntu 22.04). It asked to check at the start of Phase 6 whether JetPack 7
had gained Orin support, and to prefer it if so: FlockOS's other targets run a Debian 13
userspace of the same generation as Ubuntu 24.04.

What NVIDIA ships today (checked 2026-11-05):

| | Jetson Linux r36.5 (JetPack 6.2.2/6.2.3) | Jetson Linux r39.2.1 (JetPack 7.2.1) |
|---|---|---|
| Orin modules | AGX Orin, Orin NX, Orin Nano | AGX Orin, Orin NX, Orin Nano (since r39.2, JetPack 7.2), plus Thor |
| Released | | 2026-08-11 (r39.2: 2026-06) |
| Userspace | Ubuntu 22.04 | Ubuntu 24.04 |
| Kernel on Orin | 5.15 (`linux-jammy-nvidia-tegra`) | 6.8.12 (`linux-noble-nvidia-tegra`) |
| CUDA, TensorRT | 12.6, 10.3 | 13.2, 10.16 |
| Flashing | `flash.sh` and `l4t_initrd_flash.sh` | `l4t_initrd_flash.sh` only |
| Packages | apt: `repo.download.nvidia.com/jetson/{common,t234}` r36.x | apt: `repo.download.nvidia.com/jetson/{common,som}` r39.2, `nvidia-l4t-*` 39.2.1 |

JetPack 7.0 and 7.1 (r38) were Thor-only; r39.2 is the first release for both Orin and
Thor. Ubuntu 22.04's standard support ends in April 2027, during FlockOS 1.x.

Sources: NVIDIA's [Jetson Linux](https://developer.nvidia.com/embedded/jetson-linux) and
[JetPack](https://developer.nvidia.com/embedded/jetpack) pages, the r39.2.1 download
index and `release_sha_hashes.txt`, the apt repository index, and OE4T's
[JetPack 7.2 notes](https://github.com/OE4T/meta-tegra/blob/master/docs/release-notes/JetPack-7.2-L4T-R39.2.0-Notes.md).

## Decision (proposed)

1. `jetson-orin` is built on **Jetson Linux r39.2.1** with an **Ubuntu 24.04** (noble)
   userspace, pinned per FlockOS release (`L4T_VERSION` in the target).
2. The root filesystem is built like every other FlockOS rootfs: mmdebstrap from the
   Ubuntu noble archive plus NVIDIA's apt repositories (`common` and `som`, suite
   `r39.2`), with the `nvidia-l4t-*` packages at the pinned version. Not the 2 GB sample
   root filesystem with `apply_binaries.sh`: the image then has a package manifest, the
   same pinning as the other targets, and the overlay and bake steps unchanged.
3. The BSP tarball (`Jetson_Linux_R39.2.1_aarch64.tbz2`, 1.29 GB) is still needed for
   what is not in apt: the flash tools (`l4t_initrd_flash.sh`), the partition layout
   XML, the bootloader binaries, and capsule generation (`l4t_generate_soc_capsule.sh`)
   for lane 2. `build/fetch-bsp.sh` downloads it from NVIDIA, checks it against NVIDIA's
   SHA-1 list and against a SHA-256 pinned in this repository, and unpacks it. CI caches
   it with `actions/cache` keyed on the L4T version (WP-6.2, when there is a build to
   feed).

## Consequences

- Devices on r36 QSPI firmware need their bootloader updated to r39 once: QSPI and
  rootfs L4T versions stay in lock-step (master plan, section 3.10). For the Orin Nano
  developer kit that is NVIDIA's documented QSPI update path; for NX and AGX modules it
  is part of the initrd flash (WP-6.4). FlockOS never mixes generations.
- The Jetson image's userspace is Ubuntu, not Debian. device-init supports Ubuntu
  (`ID_LIKE=debian`). Docker CE, RAUC and fwupd come from Ubuntu noble and Docker's
  noble repository. Ubuntu 24.04 has RAUC 1.11.3 against Debian 13's 1.13: it has
  verity bundles, streaming, adaptive updates and the `custom` backend, which is
  what `jetson-orin` uses.
- Kernel 6.8 brings the Tegra audio drivers in-tree; NVIDIA's out-of-tree modules
  (`nvidia-l4t-kernel-oot-modules`) still carry the GPU and camera drivers.
- The rootfs A/B (`ROOTFS_AB=1`, `nvbootctrl -t rootfs`) and the capsule update path are
  verified on r39.2.1 in WP-6.3 and WP-6.5. The master plan's risks for r36, the retry
  counter on warm reboots and boot loops after power loss during a capsule update, are
  re-checked there.
- The RT kernel follow-up (WP-6.7) is evaluated on r39.2.1.

## Open before acceptance

- Licence review of what the image redistributes: the `nvidia-l4t-*` packages and the
  BSP's bootloader binaries are under NVIDIA's Jetson software licence, not an open
  source licence. The images carry them as NVIDIA's own SDK Manager images do, but this
  needs a legal check before FlockOS publishes Jetson images.
- Which Orin modules and carrier boards FlockOS supports first: the master plan says the
  Orin Nano developer kit (SD image) and Orin NX (flash package).

## When to revisit

- NVIDIA moves Orin to a newer JetPack line, or ends r39 maintenance for Orin.
- NVIDIA publishes the Orin bootloader and kernel in a form an upstream distribution
  builds from (a Debian-based Jetson userspace would then align `jetson-orin` with the
  other targets).
