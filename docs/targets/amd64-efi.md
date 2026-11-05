# Target amd64-efi

UEFI x86 edge PCs and industrial PCs (master plan, sections 3.2 and 3.7).

| | |
|---|---|
| Boot | UEFI only (no legacy BIOS), GRUB from the removable-media path `EFI/BOOT/BOOTX64.EFI`, no Secure Boot in 1.x |
| A/B | RAUC `grub` backend, `grubenv` on the FLOCKOS partition, `rauc.slot=` on the kernel command line |
| Kernel | Debian 13 `linux-image-amd64` (6.12 LTS), `amd64-microcode`, `intel-microcode` |
| Firmware blobs | `firmware-linux-free`, `firmware-misc-nonfree`, `-realtek`, `-iwlwifi`, `-atheros`, `-brcm80211`, `-mediatek` |
| Consoles | screen (`tty0`) and first serial port (`ttyS0`, 115200 8N1) |
| Slot size | 4 GiB (`base`), 8 GiB (`nvidia`) |
| Disk | GPT: `FLOCKOS` (ESP, 256 MiB), `rootfs-a`; `rootfs-b` and `data` made on the first boot |
| Watchdog | systemd uses a hardware watchdog when the board has one (60 s) |
| Firmware updates | fwupd (lane 3); board UEFI only where the vendor publishes capsules (section 3.10) |
| GPU (`nvidia`) | NVIDIA driver from the CUDA repository with the open kernel modules: Turing (RTX 20, T4) and newer; older GPUs need the proprietary modules, which FlockOS does not ship. Containers get the GPU through the `nvidia` runtime (`docker run --gpus all`) or CDI |

## Tested hardware

| Board | UEFI version | Date | Result | Notes |
|-------|--------------|------|--------|-------|
| QEMU q35 + OVMF (CI) | Ubuntu 24.04 `ovmf` | every pull request | `image-test` | KVM on GitHub runners; `base` and `nvidia` (no GPU) |

Hardware entries are added by WP-1.9 (`docs/testing.md`, hardware checklist).

## Notes

- Boot from USB: the image boots from the removable-media path, so no boot entry
  is needed; on boards that hide USB boot, enable it in the firmware setup.
- Some IPC firmware enables a hardware watchdog in setup; FlockOS feeds it from
  systemd once booted.
- `nvidia` on a GPU host (WP-4.2): `nvidia-smi` on the host and
  `docker run --rm --gpus all nvidia/cuda:<version>-base-ubuntu24.04 nvidia-smi`
  in a container, before and after an A/B update between two `nvidia` builds.

## Installer stick

For sealed IPCs that cannot boot a USB-flashed system disk: flash the
`installer` image with FlockFlasher, put `installer.conf` and the `.flock` on
its FLOCKOS partition, boot the IPC from the stick. Example for a box with one
NVMe and no keyboard:

```ini
# installer.conf
disk=largest
confirm=no
after=poweroff
```

The installer leaves out the stick itself, read-only, loop and too-small disks,
and USB disks unless `allow-usb=yes`. When it is done the box powers off; remove
the stick and power on. Hardware acceptance is WP-3.3.
