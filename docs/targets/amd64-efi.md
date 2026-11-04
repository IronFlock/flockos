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

## Tested hardware

| Board | UEFI version | Date | Result | Notes |
|-------|--------------|------|--------|-------|
| QEMU q35 + OVMF (CI) | Ubuntu 24.04 `ovmf` | every pull request | `image-test` | KVM on GitHub runners |

Hardware entries are added by WP-1.9 (`docs/testing.md`, hardware checklist).

## Notes

- Boot from USB: the image boots from the removable-media path, so no boot entry
  is needed; on boards that hide USB boot, enable it in the firmware setup.
- Some IPC firmware enables a hardware watchdog in setup; FlockOS feeds it from
  systemd once booted.
