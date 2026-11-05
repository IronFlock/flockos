# Target jetson-orin

NVIDIA Jetson AGX Orin, Orin NX and Orin Nano on Jetson Linux r39.2.1 (JetPack
7.2.1) with an Ubuntu 24.04 userspace (ADR-0008; Phase 6). Work in progress:
CI builds and checks the root tree (WP-6.2). The partition layout, the flash
package and the SD image are still to come (WP-6.2, WP-6.4), as are the RAUC
backend (WP-6.3) and the QSPI lane (WP-6.5).

| | |
|---|---|
| Boot | NVIDIA's UEFI firmware in QSPI starts L4TLauncher, which boots the root slot's `/boot/Image` with `/boot/initrd` (`extlinux.conf` comes with the layout) |
| A/B | NVIDIA's rootfs A/B: root slots `APP` and `APP_b`, switched through `nvbootctrl -t rootfs` by a RAUC `custom` backend (WP-6.3) |
| Distribution | `ubuntu-noble` (`distros/ubuntu-noble`): ports.ubuntu.com, Docker's noble repository |
| Kernel | `nvidia-l4t-kernel` 6.8.12 (`6.8.12-1021-tegra`) with NVIDIA's out-of-tree modules; Orin's GPU driver is `nvgpu` (`-nvgpu` packages; `-openrm` is Thor's) |
| GPU in containers | `nvidia-container-toolkit` 1.19.1 from NVIDIA's `common` repository; Docker's `nvidia` runtime (device-init's bake adds it); `nv-load-gpu-libs` links the board's `libcuda` and writes the container CSVs on each boot |
| Consoles | `ttyTCU0`, 115200 8N1 (the debug header), and the display (`tty0`) |
| Slot size | 8 GiB (`base`); only the base variant |

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

## Tests

`just rootfs jetson-orin base` builds the tree. On an arm64 host,
`sudo test/image/jetson-rootfs-check.sh <work>/flockos-jetson-orin-base/rootfs`
checks it: the versions, the sources and pins, kernel, initrd and `nvgpu`,
units and masks, the baked agent and the `nvidia` runtime. It also runs the
tree's binaries in a chroot: dpkg and apt consistency, systemd, Docker,
containerd, RAUC, `ironflock-init`, `nvidia-ctk` and `nvidia-container-cli`.
CI runs both on every pull request (`jetson-rootfs` in `ci.yml`).

## Open points

- The root device in `extlinux.conf`. NVIDIA's initrd mounts the last `root=`
  on the command line (`/dev/…`, `PARTUUID=` or `UUID=`). How L4TLauncher picks
  the slot under rootfs A/B decides between fixed partition UUIDs in the layout
  and a per-slot command line (the layout part of WP-6.2, then WP-6.3).
- `/etc/nv_boot_control.conf`, which `nvbootctrl` needs. NVIDIA's flash tools
  write it for the module (WP-6.4).
- The licence review of what the image redistributes, before the first
  published Jetson image (ADR-0008).
