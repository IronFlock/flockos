# Target rpi-arm64

Raspberry Pi 4, 400, 5, Compute Module 4 and 5, 64-bit (master plan, sections
3.2 and 3.7; Phase 5). No GRUB and no U-Boot: the Pi firmware reads
`autoboot.txt` on the first partition and starts the boot partition it names.

| | |
|---|---|
| Boot | Pi firmware (EEPROM bootloader on Pi 4 and 5), `autoboot.txt` on FLOCKOS selects the boot partition |
| A/B | the firmware's tryboot behind a RAUC `custom` backend (`/usr/lib/flockos/rpi-tryboot`); boot partition and root slot are one slot group, updated together (see below) |
| Kernel | Raspberry Pi archive: `linux-image-rpi-v8` (`kernel8.img`, Pi 4, 400, CM4) and `linux-image-rpi-2712` (`kernel_2712.img`, Pi 5, CM5); the firmware loads the one of its model and its initramfs |
| Firmware blobs | `raspi-firmware` (`start4.elf` and friends) and the archive's `firmware-brcm80211` (WiFi with the boards' NVRAM files) |
| Consoles | HDMI (`tty1`) and `serial0`, 115200 8N1 (GPIO 14/15 on Pi 4, the debug connector on Pi 5) |
| Slot size | 4 GiB (`base`) |
| Disk | GPT: `FLOCKOS` (64 MiB, `autoboot.txt`), `boot-a`, `boot-b` (256 MiB FAT each), `rootfs-a`; `rootfs-b` and `data` made on the first boot |
| Update bundle | `rootfs.ext4` and `boot.vfat` (the boot partition) |
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

## A/B with tryboot

`autoboot.txt` on FLOCKOS (mounted at `/boot/efi`) names the boot partition
the firmware starts, and the one it starts once after a tryboot reboot:

```
[all]
tryboot_a_b=1
boot_partition=2
[tryboot]
boot_partition=3
```

Slot A is boot-a (partition 2) with rootfs-a, slot B is boot-b (partition 3)
with rootfs-b. An update goes like this:

1. `rauc install` writes `boot.vfat` to the other boot partition and
   `rootfs.ext4` to the other root slot. The post-install handler gives the new
   boot partition's `cmdline.txt` its own root slot: the bundle's names slot A
   (`/usr/lib/flockos/rpi-cmdline`).
2. RAUC makes the new slot primary: the backend arms the firmware's one-shot
   tryboot flag with `vcmailbox` and records the slot as being tried
   (`/data/rauc/flockos-rpi-tryboot.state`).
3. The next reboot starts the new slot from the `[tryboot]` section. Once it is
   marked good (by the device-agent, once it reaches the platform), the backend swaps
   the two `boot_partition` values: the new slot is the primary.
4. If the new slot does not come up and the device reboots (kernel panic,
   watchdog, power cycle), the flag is gone and the old primary starts again.
   The tried slot reads as bad.

The backend never makes a slot primary that has not booted: the firmware has
no fallback from a broken `[all] boot_partition`. The booted partition and the
tryboot flag come from the firmware's device tree (`/chosen/bootloader`).

It follows Rtone's `raspberrypi-firmware-rauc-bootloader-backend` and
Bootlin's "Safe updates using RAUC on Raspberry Pi 5". The differences:

- Slot states persist on `/data`, so the slot that was replaced stays good and
  a failed try reads as bad after the fallback. Rtone derives every state from
  the current boot.
- Only the running slot can be marked good. `set-state` of the primary to bad
  hands the next boot to the other slot only when that slot runs or is known
  good.
- Boot partition numbers are FlockOS's fixed layout (2 is A, 3 is B), not looked
  up in `system.conf`.
- `cmdline.txt` is rewritten by the post-install handler. Bootlin prefers
  `[boot_partition=N]` filters in `config.txt`, which need an EEPROM from
  2025-03 and are undocumented.

A cold power cycle clears a pending tryboot, so an update reboots warm
(`systemctl reboot`).

## Tested hardware

| Board | EEPROM version | Date | Result | Notes |
|-------|----------------|------|--------|-------|
| none yet | | | `rpi-check` in CI only | WP-5.4: Pi 4 and Pi 5 |

Pi-specific items of the hardware checklist (`docs/testing.md`, WP-5.4):

1. `rpi-eeprom-update` shows a bootloader from 2020-10 or later (Pi 4); the
   first boot reaches the console on HDMI and on `serial0`.
2. `rauc status` shows slot A booted, B bad, primary A.
3. `rauc install` of the next build's bundle, then `systemctl reboot`: the
   device comes up on B (`rauc status`: booted B), and after the agent's
   mark-good `autoboot.txt` has `boot_partition=3` in `[all]`.
4. Fallback: install again (into A), then break that slot's boot before the
   reboot, for example by adding `init=/bin/false` to `cmdline.txt` on its
   boot partition. The tryboot panics, `panic=10` reboots, and the device is
   back on B with A reported bad.

## Checks without a Pi

QEMU cannot run the Pi firmware's boot path. CI runs `test/image/rpi-check.sh`
on the arm64 runner. It checks the partition layout, `autoboot.txt`, boot-a's
files and `cmdline.txt` against slot A's PARTUUID, the kernels against the
tree's, slot A's units, RAUC configuration and baked agent, and runs some of
the image's own programs in a chroot.
