# Target rpi-arm64

Raspberry Pi 4, 400, 5, Compute Module 4 and 5, 64-bit (master plan, sections
3.2 and 3.7; Phase 5). No GRUB and no U-Boot: the Pi firmware reads
`autoboot.txt` on the first partition and starts the boot partition it names.

| | |
|---|---|
| Boot | Pi firmware (EEPROM bootloader on Pi 4 and 5), `autoboot.txt` on FLOCKOS selects the boot partition |
| A/B | WP-5.1: none yet, RAUC runs its `noop` backend. WP-5.2: tryboot, RAUC `custom` backend, boot partition and root slot updated as one group |
| Kernel | Raspberry Pi archive: `linux-image-rpi-v8` (`kernel8.img`, Pi 4, 400, CM4) and `linux-image-rpi-2712` (`kernel_2712.img`, Pi 5, CM5); the firmware loads the one of its model and its initramfs |
| Firmware blobs | `raspi-firmware` (`start4.elf` and friends) and the archive's `firmware-brcm80211` (WiFi with the boards' NVRAM files) |
| Consoles | HDMI (`tty1`) and `serial0`, 115200 8N1 (GPIO 14/15 on Pi 4, the debug connector on Pi 5) |
| Slot size | 4 GiB (`base`) |
| Disk | GPT: `FLOCKOS` (64 MiB, `autoboot.txt`), `boot-a`, `boot-b` (256 MiB FAT each), `rootfs-a`; `rootfs-b` and `data` made on the first boot |
| EEPROM | `rpi-eeprom` in the image; the update lane is WP-5.3 |

The Pi 4's EEPROM must be from 2020-10 or later to boot GPT and read
`autoboot.txt`. Pi 3 and Zero 2 W are not supported by this target: their
firmware has neither (master plan, section 3.2).

## The boot partition

`boot-a` holds what `raspi-firmware`'s hooks put into `/boot/firmware` while
the image is built (firmware, both kernels, both initramfs images, the device
trees and overlays), plus FlockOS's `config.txt` and `cmdline.txt`
(`targets/rpi-arm64/boot`). `cmdline.txt` mounts slot A by PARTUUID and names
it for RAUC (`rauc.slot=A`). In the root filesystem `/boot/firmware` is an
empty directory.

The Raspberry Pi archive is in the image's apt sources, below Debian: Debian's
packages win, except `raspi-firmware` and `firmware-brcm80211`.

## Tested hardware

| Board | EEPROM version | Date | Result | Notes |
|-------|----------------|------|--------|-------|
| none yet | | | `rpi-check` in CI only | WP-5.4: Pi 4 and Pi 5 |

## Checks without a Pi

QEMU cannot run the Pi firmware's boot path. CI runs `test/image/rpi-check.sh`
on the arm64 runner. It checks the partition layout, `autoboot.txt`, boot-a's
files and `cmdline.txt` against slot A's PARTUUID, the kernels against the
tree's, slot A's units, RAUC configuration and baked agent, and runs some of
the image's own programs in a chroot.
