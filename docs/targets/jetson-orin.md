# Target jetson-orin

NVIDIA Jetson AGX Orin, Orin NX and Orin Nano on Jetson Linux r39.2.1 (JetPack
7.2.1) with an Ubuntu 24.04 userspace (ADR-0008; Phase 6). Work in progress:
CI builds slot A's filesystem image and the RAUC bundle and checks the root
tree (WP-6.2). Those CI jobs (`jetson-rootfs`, `jetson-flash`) are switched
off for now to save CI time, until the Jetson work continues. Still to come:

- the flash dry run (WP-6.2);
- the flash package and the SD image (WP-6.4);
- the RAUC backend (WP-6.3);
- the QSPI lane (WP-6.5).

| | |
|---|---|
| Boot | NVIDIA's UEFI firmware in QSPI starts L4TLauncher, which reads the root slot's `/boot/extlinux/extlinux.conf` and boots its `/boot/Image` with `/boot/initrd` (see below) |
| A/B | NVIDIA's rootfs A/B: root slots `APP` and `APP_b`, switched through `nvbootctrl -t rootfs` by a RAUC `custom` backend (WP-6.3) |
| Distribution | `ubuntu-noble` (`distros/ubuntu-noble`): ports.ubuntu.com, Docker's noble repository |
| Kernel | `nvidia-l4t-kernel` 6.8.12 (`6.8.12-1021-tegra`) with NVIDIA's out-of-tree modules; Orin's GPU driver is `nvgpu` (`-nvgpu` packages; `-openrm` is Thor's) |
| GPU in containers | `nvidia-container-toolkit` 1.19.1 from NVIDIA's `common` repository; Docker's `nvidia` runtime (device-init's bake adds it); `nv-load-gpu-libs` links the board's `libcuda` and writes the container CSVs on each boot |
| Consoles | `ttyTCU0`, 115200 8N1 (the debug header), and the display (`tty0`) |
| Slot size | 8 GiB (`base`); only the base variant |
| Disk | NVIDIA's NVMe layout for rootfs A/B, plus `data` (see below); written by NVIDIA's flash tools |
| Image | `<image-id>-<version>.rootfs.ext4.zst`, slot A's filesystem (APP), and the bundle `<image-id>-<version>.raucb` |

## Packages and pins

NVIDIA's repositories `https://repo.download.nvidia.com/jetson/{common,som}`,
suite `r39.2`, go into the image's sources (`nvidia-l4t.sources`) below Ubuntu:
for a package both have, Ubuntu's version wins. The repositories carry several
L4T releases, so `flockos-l4t.pref` holds every `nvidia-l4t-*` binary at
`L4T_PACKAGE_VERSION`, the kernel's binaries at `L4T_KERNEL_VERSION` and the
container toolkit at `L4T_CONTAINER_TOOLKIT_VERSION` (all in `target.conf`). The
build also pins the packages `targets/jetson-orin/packages` lists on mmdebstrap's
command line, so a version NVIDIA withdraws fails the build.

The repositories' key is `targets/jetson-orin/apt/jetson-ota-public.asc`
(fingerprint `3C6D1FF3100C8C3ABB0869C0E6543461A9996195`, checked by the unit
tests). It is the file `nvidia-l4t-apt-source` 39.2.1 ships, byte for byte the
copy in the pinned BSP tarball, and it signs both repositories' `InRelease`.

Left out on purpose:

- `nvidia-l4t-bootloader`: the QSPI payloads; the QSPI firmware has its own lane (WP-6.5).
- `nvidia-l4t-extlinux`: the build writes `extlinux.conf`.
- `nvidia-l4t-apt-source`: the build writes the sources.
- `nvidia-l4t-configs`: desktop, Weston and cloud-init settings.

NVIDIA's packages check the board they are installed on and update its boot
firmware unless `/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall`
exists. The build creates the marker before the packages go in and removes it
afterwards, as NVIDIA's own image build does.

## Services

FlockOS masks two of NVIDIA's boot-time services:

- `nv-l4t-bootloader-config` updates the QSPI firmware by itself. FlockOS's lane 2 does that (WP-6.5).
- `nv-rootfs-validation-config` marks the root slot good. FlockOS's health gate does that (WP-6.3).

The rest of `nvidia-l4t-init` stays enabled as NVIDIA presets it: GPU libraries,
display modules, power model, fan control.

There is no `repart.d` on this target: NVIDIA's flash tools write the whole
layout, the `data` partition included.

## Booting a slot

Each root slot boots with its own `/boot/extlinux/extlinux.conf`, rendered
from `targets/jetson-orin/boot/extlinux.conf`. NVIDIA's initrd mounts the
last `root=` on the command line (`/dev/…`, `PARTUUID=` or `UUID=`). Under
rootfs A/B, NVIDIA's `flash.sh` gives each slot its own command line, with
`root=PARTUUID=` of `APP` or `APP_b`, and L4TLauncher does not rewrite it.
FlockOS does the same:

- The image's file names slot A: `root=PARTUUID=` of `APP`, derived from the
  image id (`uuid_for rootfs-a`, which the flash package gives `APP`), and
  `rauc.slot=A`.
- RAUC writes one image into either slot, so `rauc-post-install` runs
  `/usr/lib/flockos/tegra-extlinux` on the slot it has just written. That
  points the slot's `APPEND` line at its own PARTUUID and bootname, as
  `rpi-cmdline` does for the Pi's `cmdline.txt`.

The rest of the command line is NVIDIA's for the Orin modules (`TEGRA_CMDLINE`
in `target.conf`, from `CMDLINE_ADD` of `p3701.conf.common` and
`p3767.conf.common`). L4TLauncher fills in `${cbootargs}`.

## Partition layout

NVIDIA's flash tools partition and write a Jetson's disk; FlockOS does not
make a disk image for it. `build/tegra-layout.py` takes the BSP's
`tools/kernel_flash/flash_l4t_t234_nvme_rootfs_ab.xml` and adds FlockOS's
`data` partition after `APP_b`. That partition grows to the end of the disk
(allocation attribute `0x808`, as NVIDIA's single-slot layout grows `APP`) and
is mounted at `/data` (`PARTLABEL=data`). NVIDIA's layout files are under
NVIDIA's licence, so the layout is generated from the BSP when the flash
package is made, never copied into this repository. The script refuses a
layout of another shape, so a BSP that changes it fails instead of flashing
something unexpected. The partitions:

| Partition | Content |
|-----------|---------|
| `A_kernel`, `B_kernel`, `A_kernel-dtb`, `B_kernel-dtb`, recovery | NVIDIA's, from the BSP (the fallback when the root slot does not boot) |
| `esp` | the EFI system partition with L4TLauncher; `/boot/efi`, where the `.flock` to enroll with goes |
| `APP`, `APP_b` | root slots A and B (`SLOT_SIZE_BASE`) |
| `data` | `/data`, to the end of the disk; GPT entry 17 (explicit: counted on from `APP_b`'s 2, it would take `A_kernel`'s 3) |

The ESP keeps NVIDIA's name `esp`, because `flash.sh` makes its image only
under that name. On the other targets that role belongs to `FLOCKOS`, so the
build points `/boot/efi` in this target's `/etc/fstab` at `PARTLABEL=esp`.

The build's image is slot A's filesystem, `<image-id>-<version>.rootfs.ext4.zst`
(`build/mkimage-tegra.sh`), with an `extlinux.conf` that boots slot A. The
flash package takes it for `APP`, and a copy pointed at slot B for `APP_b`
(`tegra-extlinux`); NVIDIA's tools' `-r` option reuses prebuilt slot images,
so `flash.sh` does not rebuild them from a tree with its own kernel and
command line.

## Flash package

`build/tegra-flash-package.sh` makes the flash package of an Orin on NVMe on
the flashing host (x86_64 Ubuntu with the BSP's
`tools/l4t_flash_prerequisites.sh`), offline: no Jetson needs to be attached,
the module is named by its board ID and SKU. It runs NVIDIA's
`ROOTFS_AB=1 l4t_initrd_flash.sh --no-flash -r --external-device nvme0n1 -c <layout> --external-only <board> external`
after preparing the unpacked BSP:

- the layout from `build/tegra-layout.py`;
- `bootloader/system.img` (APP) from the slot image, and `system.img_b`
  (APP_b), the same pointed at slot B through `debugfs` (no mount);
- the slots' PARTUUIDs, the ones their `extlinux.conf` names (`uuid_for
  rootfs-a`/`rootfs-b`), in `flash.sh`'s UUID files `l4t-rootfs-uuid.txt_ext`
  and `_b_ext`;
- `rootfs/`: slot A's tree, which NVIDIA's tools read (the board's
  compatible spec), plus what the flashing initrd and the recovery ramdisk
  take from it and the image does not carry: `mtd-utils`, `file`, `parted`,
  `nvidia-l4t-optee`, `busybox`, `fdisk`, `gdisk`, `libnsl2`, `libpcre3`,
  `isc-dhcp-client`, installed into that copy (a chroot through qemu-user)
  from the image's own sources and pins;
- a fix of NVIDIA's `-r` option: `l4t_initrd_flash.func` and
  `l4t_create_images_for_kernel_flash.sh` declare it with an argument in
  their getopts strings, though it takes none, so it swallows the next option
  and every later option is lost. The script makes it a flag, and fails where
  the BSP's string is not the known one.

The package lands in the BSP's `tools/kernel_flash/images`: the external
device's GPT and flash index, ESP, boot and recovery images, and APP/APP_b as
NVIDIA's tarballs. `l4t_initrd_flash.sh --flash-only` writes it to a module in
recovery mode (WP-6.4). CI makes it for an Orin Nano 8GB (`3767`/`0003`) on
`jetson-orin-nano-devkit` on every pull request (`jetson-flash`), with the
BSP tarball cached by its pin; there `l4t_initrd_flash.sh` gets an empty USB
bus in a mount namespace of its own, as it fails where there is none even
with `--no-flash`.

## Tests

`just build jetson-orin base` builds the image and leaves the tree in
`<work>/flockos-jetson-orin-base/rootfs`. On an arm64 host,
`sudo test/image/jetson-rootfs-check.sh <work>/flockos-jetson-orin-base/rootfs`
checks it: the versions, the sources and pins, kernel, initrd and `nvgpu`,
units and masks, the baked agent and the `nvidia` runtime. It also runs the
tree's binaries in a chroot: dpkg and apt consistency, systemd, Docker,
containerd, RAUC, `ironflock-init`, `nvidia-ctk` and `nvidia-container-cli`.
CI runs both on every pull request (`jetson-rootfs` in `ci.yml`), and makes
the flash package from the image (`jetson-flash`, above).

## Open points

- `/etc/nv_boot_control.conf`, which `nvbootctrl` needs: `flash.sh` writes
  it for the module into the BSP's `rootfs/`, and with `-r` it does not reach
  the slot images. The flash package has to put it into APP and APP_b
  (WP-6.4).
- The internal storage (QSPI) images: `--external-only` leaves them out. A
  module needs them once (r39 bootloader; NVIDIA's two-step `--no-flash
  --reuse ... internal`, then `--external-only --append`) (WP-6.4).
- The `.flock` on the ESP for enrollment (WP-6.4).
- Licences ([jetson-licence-review.md](../jetson-licence-review.md); done
  2026-11-07, legal sign-off in WP-6.8). Jetson Linux is under the NVIDIA
  Driver License Agreement: NVIDIA's binaries may be redistributed only
  unchanged, and every recipient must get the Agreement. What follows for this
  target:
  - the build keeps NVIDIA's packages and their `/usr/share/doc` unchanged
    (a rootfs check will enforce it);
  - `apt/jetson-ota-public.asc` is replaced with the key as
    `repo.download.nvidia.com` serves it, without NVIDIA's licence header;
  - the flash package stays a CI test, and users get a flash kit that
    downloads the BSP from NVIDIA (WP-6.4);
  - the QSPI capsule comes unchanged from `nvidia-l4t-bootloader` (WP-6.5).
