# ADR-0008: Jetson Orin on Jetson Linux r39.2.1 (JetPack 7.2.1), Ubuntu 24.04

Status: accepted, 2026-11-05 (WP-6.1), on one condition: the licence review below passes
before IronFlockOS publishes a Jetson image. The review was done on 2026-11-07; the legal
sign-off is open (WP-6.8).

## Context

The master plan (sections 3.7 and Phase 6) put `jetson-orin` on Jetson Linux r36.x
(JetPack 6, Ubuntu 22.04). It asked to check at the start of Phase 6 whether JetPack 7
had gained Orin support, and to prefer it if so: IronFlockOS's other targets run a Debian 13
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
Thor. Ubuntu 22.04's standard support ends in April 2027, during IronFlockOS 1.x.

Sources: NVIDIA's [Jetson Linux](https://developer.nvidia.com/embedded/jetson-linux) and
[JetPack](https://developer.nvidia.com/embedded/jetpack) pages, the r39.2.1 download
index and `release_sha_hashes.txt`, the apt repository index, and OE4T's
[JetPack 7.2 notes](https://github.com/OE4T/meta-tegra/blob/master/docs/release-notes/JetPack-7.2-L4T-R39.2.0-Notes.md).

## Decision

1. `jetson-orin` is built on **Jetson Linux r39.2.1** with an **Ubuntu 24.04** (noble)
   userspace, pinned per IronFlockOS release (`L4T_VERSION` in the target).
2. The root filesystem is built like every other IronFlockOS rootfs: mmdebstrap from the
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
  is part of the initrd flash (WP-6.4). IronFlockOS never mixes generations.
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

## Condition and open points

- Condition: a licence review of what the image redistributes, and a legal check of it,
  before IronFlockOS publishes a Jetson image (the release of WP-6.6). Building and testing
  in CI do not wait for it. The review is done
  ([jetson-licence-review.md](../jetson-licence-review.md), 2026-11-07). The legal
  check is WP-6.8. What the review found:
  - The BSP and every `nvidia-l4t-*` package of r39.2.1 are under one agreement, the
    **NVIDIA Driver License Agreement**. It is not an open source licence. Its section
    1.1(d) permits distribution for use with an open source kernel, on two conditions:
    the binary files stay unmodified, and every recipient gets the Agreement. The
    kernel, its modules and the DTBs are GPL-2.0, so their source has to be
    available. The SPE firmware in the bootloader contains FreeRTOS, which needs a
    written source offer with every copy.
  - As a result, the image and the bundle carry NVIDIA's packages unchanged, with their
    notices. The Agreement goes next to every Jetson file. NVIDIA's
    `public_sources.tbz2` is mirrored with each release. The QSPI capsule is NVIDIA's
    own from `nvidia-l4t-bootloader` where NVIDIA ships one. IronFlockOS does not publish
    the flash package: a flash kit fetches the BSP from NVIDIA on the user's host.
    IronFlockOS publishes images that NVIDIA's tools make from the BSP (the flash package,
    the SD image, generated capsules) only if legal accepts them as unmodified
    binaries. This changes decision 3: the BSP still provides the flash tools in CI and
    in the flash kit. Capsule generation is needed only for carrier boards that
    NVIDIA ships no capsule for.
  - Open for legal: the review's eight questions (the points above, the indemnity, the
    critical-applications exclusion, export control, Canonical's IP policy for the
    Ubuntu userspace, and the revocable licence).
- First modules and carrier boards: the master plan's Orin Nano developer kit (SD image)
  and Orin NX (flash package), unless the hardware available for the acceptance tests
  says otherwise (master plan, open question 3).

## When to revisit

- NVIDIA moves Orin to a newer JetPack line, or ends r39 maintenance for Orin.
- NVIDIA publishes the Orin bootloader and kernel in a form an upstream distribution
  builds from (a Debian-based Jetson userspace would then align `jetson-orin` with the
  other targets).
