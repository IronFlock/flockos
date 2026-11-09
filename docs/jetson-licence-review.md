# Jetson licence review

Status: technical review done 2026-11-07 (WP-6.1); IronFlock's legal sign-off is open
(WP-6.8). It is the condition of [ADR-0008](adr/0008-jetson-orin-bsp-jetpack-7.md):
IronFlockOS publishes no Jetson image before the questions at the end are answered.
Building and testing in CI do not wait for it.

This document is not legal advice. It collects what the licence texts of Jetson Linux
r39.2.1 say, what IronFlockOS distributes, and what IronFlockOS does to meet the terms. The
texts were read from the files NVIDIA ships, not from summaries.

## What was read

- The **NVIDIA Driver License Agreement**: the BSP's
  `Tegra_Software_License_Agreement-Tegra-Linux.txt` of r39.2.1 (SHA-1
  `e331f3658ad9569817848036b6889d2bedcab18a`, as in NVIDIA's `release_sha_hashes.txt`).
  The file keeps its old name, but its text is the Driver License Agreement. The
  `copyright` file of every `nvidia-l4t-*` package IronFlockOS installs carries the same
  text, and so does `/usr/share/doc/nvidia-l4t-core/`. NVIDIA's JetPack EULA page
  names the same agreement (v. 2023-11-23) for "JetPack OS". Its section 1.1(d) says
  "operating systems", while the r39.2.1 copy says "operating system kernels"; this
  review uses the r39.2.1 copy.
- The per-component `LICENSE.*` and `NOTICE.*` files of the 22 packages in
  `targets/jetson-orin/packages`, of `nvidia-l4t-bootloader`, and of the BSP tarball
  (`bootloader/`, `kernel/`, `generate_capsule/`, `tools/`, `nv_tegra/`).
- `NVIDIA_Trademark_License_Addendum_SW.pdf` in `nvidia-l4t-tools`.
- The contents of NVIDIA's `public_sources.tbz2` of r39.2.1.
- Canonical's intellectual property policy, because the userspace is Ubuntu.

## What IronFlockOS distributes

| Artefact | NVIDIA content | Channel | State |
|----------|----------------|---------|-------|
| Slot image `<image-id>-<version>.rootfs.ext4.zst` and bundle `.raucb` | The `nvidia-l4t-*` packages the target lists and their dependencies, and the container toolkit, installed by dpkg from NVIDIA's repositories | Download server `flockos/<version>/`, appliance OS mirror, FlockFlasher, the device-agent | Built in CI (WP-6.2) |
| Flash package | Bootloader binaries, BCTs and partition images that NVIDIA's tools make from the BSP; NVIDIA's host flash tools; two NVIDIA scripts with IronFlockOS's `-r` fix; the layout `build/tegra-layout.py` makes from NVIDIA's XML | Planned for the release matrix (WP-6.4) | Built in CI, not published |
| Orin Nano SD image | The same for an SD card: kernel, DTB, ESP with L4TLauncher, recovery | FlockFlasher (WP-6.4) | Planned |
| QSPI capsule `TEGRA_BL.Cap` | The bootloader binaries (MB1, MB2, BPMP, SPE, RCE, UEFI, OP-TEE, TF-A) in one capsule | Inside the bundle (WP-6.5) | Planned |
| Repository | `targets/jetson-orin/apt/jetson-ota-public.asc`, NVIDIA's key file with the header `LicenseRef-NvidiaProprietary` | GitHub, public, Apache-2.0 | Now |

IronFlockOS does not distribute NVIDIA's sample root filesystem (ADR-0008). It also does not
distribute the JetPack SDK components (CUDA toolkit, cuDNN, TensorRT). These have their
own agreements, such as the CUDA EULA with its list of distributable files. Containers
bring these components. `nvidia-l4t-cuda` is the driver's `libcuda`, under the Driver
License Agreement. If the image gets a JetPack SDK component later, that component needs
a review of its own.

## The NVIDIA Driver License Agreement

The section numbers are those of the r39.2.1 text.

| Section | Says | For IronFlockOS |
|---------|------|-------------|
| 1.1(d) | You may distribute the SOFTWARE for use with operating system kernels under an OSI-approved open source licence, provided that (i) the binary files are not modified in any way (except for uncompressing compressed files) and (ii) this Agreement is provided to each SOFTWARE recipient | This is the grant IronFlockOS depends on. Linux is GPLv2, so it qualifies. NVIDIA's binaries must stay unchanged, and everyone who gets an image must get the Agreement |
| 1.1(b) | You may modify and create derivative works of the parts NVIDIA delivers in source code form | IronFlockOS's fix to two of NVIDIA's flash scripts and the layout it generates from NVIDIA's XML are such changes (question 2) |
| 2.1 | Only for NVIDIA's chips (the "NVIDIA Platform"); firmware only on them | The packages go only into `jetson-orin` images, and `nvidia-l4t-core` refuses other boards |
| 2.2, 2.3, 2.4 | No reverse engineering, no changes to or derivative works of binaries, no modified headers | |
| 2.5 | Keep copyright and proprietary notices; a modified file must carry a prominent notice that it was changed | `/usr/share/doc/nvidia-l4t-*` stays in the image |
| 2.6 | Do not bypass technical limits or security mechanisms | Masking `nv-l4t-bootloader-config` and `nv-rootfs-validation-config` disables no security mechanism; IronFlockOS's lane 2 and health gate do their work |
| 2.7 | Except as granted, you may not sell, rent, sublicense, distribute or transfer the SOFTWARE, or provide commercial hosting services with it. The licence is non-sublicensable | The recipient's licence comes from NVIDIA through the Agreement, not from IronFlockOS. IronFlockOS's Apache-2.0 does not cover NVIDIA's parts |
| 2.9 | Do not use the SOFTWARE in a way that would make it subject to an open source licence | An image that holds NVIDIA's binaries next to GPL programs is an aggregate; IronFlockOS links nothing to NVIDIA's binaries |
| 2.10 | Not tested or certified for Critical Applications (avionics, navigation, autonomous vehicles, automotive, military, medical, life support); the licensee is responsible for safety and redundancy | Applies to IronFlock's customers |
| 2.11 | The licensee defends and indemnifies NVIDIA against claims from products or services developed with or using the SOFTWARE | A business risk for IronFlock |
| 7 | Ends automatically on a breach; earlier distributions are not affected | |
| 8 | Cooperate with NVIDIA to verify compliance | |
| 12 | NVIDIA's liability is limited to US$5 | |
| 15 | Comply with export, import and sanctions law | |
| 10 | Arbitration (JAMS, Santa Clara), Delaware law | |

## Other licences inside

| Component | Licence | What it asks |
|-----------|---------|--------------|
| Kernel `Image`, out-of-tree modules, DTBs (`nvidia-l4t-kernel`, `-kernel-oot-modules`, `-kernel-nvgpu`, `-kernel-dtbs`) | GPL-2.0; `nvgpu` GPL-2.0-only with MIT parts | The corresponding source. NVIDIA's notice points to `source_sync.sh` or `oss-requests@nvidia.com`. NVIDIA's `public_sources.tbz2` (295 MB) holds the kernel, the out-of-tree modules and `nvgpu` |
| `libnvidia-container1` | Apache-2.0, LGPL-3.0+, BSD-3-Clause, MIT | The LGPL parts' source (GitHub, tag `v1.19.1`) |
| `nvidia-container-toolkit` | Apache-2.0 | Notices |
| `nvidia-l4t-init` configs, `nvethernetrm`, display parts | MIT | Notices |
| NVDLA (FlatBuffers), `tipc_test`, the BSD parts of `nvbootctrl` | Apache-2.0, BSD | Notices |
| Realtek Wi-Fi and Bluetooth firmware (`nvidia-l4t-firmware`) | Realtek's binary licence: redistribution without modification, notice reproduced, no reverse engineering | Unchanged, with the notice |
| PVA firmware (`nvidia-l4t-firmware`, `NOTICE.nvpva-fw`) | In addition to the Agreement: you may not communicate or publish any performance or statistical data specific to this firmware | IronFlockOS publishes no PVA figures |
| SPE firmware (`spe_t234.bin`: bootloader, capsule) | FreeRTOS V8.1.2 under a modified GPL with an exception | Every copy must come with a written statement of the FreeRTOS version and the distributor's own offer to provide its source. Clause 2 forbids publishing FreeRTOS run-time or compile-time metrics. `public_sources.tbz2` holds `FreeRTOSV8.1.2_src.tbz2` and `spe-freertos-bsp.tbz2` |
| UEFI (L4TLauncher `BOOTAA64.efi`, `uefi_t23x_*.bin`), Standalone MM | BSD-2-Clause-Patent, with NVIDIA's proprietary parts | Notices |
| OP-TEE, TF-A | BSD | Notices; the source is in `public_sources.tbz2` |
| MB1, MB2, BPMP, RCE, ADSP | NVIDIA proprietary (the Agreement), with BSD and MIT parts | As the Agreement |
| NVIDIA trademarks | The trademark addendum: the NVIDIA logos and the word "Jetson" may be used on goods that use NVIDIA products, following NVIDIA's guidelines, but not in a way that suggests NVIDIA provides or supervises the goods | Board names in text, no logos |

**Ubuntu.** Canonical's IP policy (2015-07-15) says that a modified version of Ubuntu may
be redistributed only if Canonical approves, certifies or provides it. Otherwise the
Ubuntu trademarks must be removed and replaced, and the binaries recompiled. The policy
also says that Ubuntu is an aggregate work, and that it does not reduce the rights the
licences of its packages grant. IronFlockOS's `jetson-orin` image carries IronFlockOS's name and
uses Canonical's binaries from `ports.ubuntu.com`.

## What IronFlockOS does

1. **NVIDIA's packages stay unchanged.** dpkg installs them from NVIDIA's repositories at
   the pinned version. The build changes none of their files. It writes its own
   `extlinux.conf`, masks two of NVIDIA's units, and leaves out `nvidia-l4t-bootloader`,
   `-extlinux`, `-apt-source` and `-configs` (target notes). The build excludes no
   documentation, so `/usr/share/doc/nvidia-l4t-*` keeps the Agreement and the notices.
   A check in `test/image/jetson-rootfs-check.sh` makes this a rule: every installed
   `nvidia-l4t-*` package has its `copyright` file (WP-6.8).
2. **The Agreement goes with every Jetson file.** NVIDIA's text, byte for byte the BSP's,
   is published as `NVIDIA-LICENSE.txt` next to the Jetson files in `flockos/<version>/`.
   The release notes link it. FlockFlasher shows it before it writes a Jetson image.
   Devices that update over the air get it inside the bundle (WP-6.8).
3. **IronFlockOS mirrors NVIDIA's sources.** Each Jetson release puts NVIDIA's
   `public_sources.tbz2` of its L4T version, and the `libnvidia-container` source of its
   tag, on the download server (`flockos/sources/l4t-<version>/`). This is IronFlock's
   own source offer. Passing on NVIDIA's offer (GPLv2 section 3(c)) is allowed only for
   noncommercial distribution. The same mirror holds FreeRTOS for the capsule's offer
   (WP-6.8).
4. **IronFlockOS does not publish the flash package.** CI still makes it on every pull request
   as a test. Users get a flash kit instead: IronFlockOS's own scripts. On the flashing host,
   the kit downloads the pinned BSP from NVIDIA, checks it against the SHA-256 in
   `bsp.conf`, and runs what CI runs (`build/tegra-flash-package.sh`) with the published
   slot image. The user gets the BSP from NVIDIA under the Agreement. IronFlockOS then
   distributes no NVIDIA-made bootloader images, no changed NVIDIA scripts and no
   derived layout. IronFlockOS publishes the package itself only if legal answers
   questions 1 and 2 with yes (WP-6.4).
5. **The Orin Nano SD image waits for question 1.** It holds partition images that
   NVIDIA's tools make. If the answer is no, the developer kit also uses the flash kit
   (WP-6.4).
6. **The QSPI capsule is NVIDIA's own where NVIDIA ships one.** `nvidia-l4t-bootloader`
   at the pinned version has prebuilt capsules for NVIDIA's carrier boards
   (`/opt/ota_package/t23x/TEGRA_BL_3767*.Cap` for Orin NX and Nano,
   `TEGRA_BL_3701*.Cap` for AGX Orin). The bundle carries the capsule unchanged. WP-6.5
   checks that the capsule matches the QSPI firmware the flash kit writes.
   `l4t_generate_soc_capsule.sh` makes capsules only for carriers NVIDIA ships none for,
   and only after legal answers question 1 with yes. The bundle carries the FreeRTOS
   statement: version 8.1.2, and the offer that points at the source mirror (WP-6.5).
7. **The repository holds no file under NVIDIA's licence.** NVIDIA's layout files stay
   out already. `jetson-ota-public.asc` is replaced with the key as NVIDIA serves it at
   `https://repo.download.nvidia.com/jetson/jetson-ota-public.asc`. That file has the
   same key block and the same fingerprint, `3C6D1FF3100C8C3ABB0869C0E6543461A9996195`,
   and no licence header (WP-6.8).
8. **Names, not logos.** IronFlockOS's documents and FlockFlasher name the boards in text,
   for example "NVIDIA Jetson Orin Nano Developer Kit". They show no NVIDIA logos and say
   nothing that suggests NVIDIA provides or supports IronFlockOS.
9. **No PVA or FreeRTOS figures.** IronFlockOS publishes no performance data of the PVA
   firmware or of FreeRTOS on the SPE. The real-time figures of WP-6.7 measure Linux on
   the CPU cores.

## Questions for legal

IronFlock's legal check answers these before the first published Jetson image (WP-6.8).
If an answer is no, the fallback in the same row applies, or IronFlock asks NVIDIA for
written permission.

| # | Question | If no |
|---|----------|-------|
| 1 | Are images that NVIDIA's own tools make from unchanged BSP binaries "binary files not modified" under 1.1(d)? This covers signed or packed binaries, BCTs, partition images and capsules | Flash kit only; no SD image; capsules only from `nvidia-l4t-bootloader` |
| 2 | May IronFlockOS distribute two of NVIDIA's flash scripts with its `-r` fix, and a layout generated from NVIDIA's XML, if they carry change notices (1.1(b), 2.5)? | The flash kit applies the fix and makes the layout on the user's host, as CI does |
| 3 | Is the Agreement next to the download, in FlockFlasher and in the image enough for "provided to each SOFTWARE recipient"? Does FlockFlasher need an acceptance step? What about devices that partners sell with IronFlockOS already installed? | FlockFlasher asks for acceptance; partners pass the Agreement on |
| 4 | Does IronFlock accept the indemnity (2.11)? Do its customer terms pass the exclusion of Critical Applications (2.10) on for Jetson devices? | Customer terms change before the first Jetson release |
| 5 | How are the Jetson images classified for export control (15)? NVIDIA's proprietary parts are not publicly available open source. Does the download server need restrictions for embargoed destinations? | Jetson files go behind the restriction the answer names |
| 6 | Is the source mirror (point 3) enough for NVIDIA's GPL and LGPL parts? The same question applies to the Ubuntu and Debian packages of every IronFlockOS image | As legal sets |
| 7 | Is a IronFlockOS-branded image built from Canonical's Ubuntu binaries fine under Canonical's IP policy? | A licence from Canonical, or a userspace IronFlockOS builds itself |
| 8 | The licence is revocable, and every Jetson device in the field depends on it. Does IronFlock accept that, or does it seek a written distribution agreement with NVIDIA, for example through NVIDIA's partner programme? | |

## Sources

- NVIDIA, Jetson Linux r39.2.1: `release_sha_hashes.txt`,
  `Tegra_Software_License_Agreement-Tegra-Linux.txt`, `Jetson_Linux_R39.2.1_aarch64.tbz2`,
  `sources/public_sources.tbz2`, at
  `https://developer.download.nvidia.com/embedded/L4T/r39_Release_v2.1/`.
- NVIDIA's apt repositories `https://repo.download.nvidia.com/jetson/{som,common}`, suite
  `r39.2`: the packages of `targets/jetson-orin/packages` at their pins, and
  `nvidia-l4t-bootloader` 39.2.1.
- [EULA - JetPack](https://docs.nvidia.com/jetson/jetpack/eula/index.html): the NVIDIA
  Driver License Agreement for JetPack OS, and the CUDA EULA.
- [Canonical's intellectual property policy](https://canonical.com/legal/intellectual-property-policy).
