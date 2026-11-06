# Target arm64-efi

Generic arm64 machines with UEFI: edge servers and boxes with Arm SystemReady
firmware, and arm64 virtual machines (master plan, Phase 7; WP-7.1). The
Raspberry Pi and Jetson Orin have their own targets.

| | |
|---|---|
| Boot | UEFI only, GRUB from the removable-media path `EFI/BOOT/BOOTAA64.EFI`, no Secure Boot in 1.x |
| A/B | as amd64-efi: RAUC `grub` backend, `grubenv` on the FLOCKOS partition. Boot script, `system.conf`, disk layout and `repart.d` are amd64-efi's files (symlinks in `targets/arm64-efi`) |
| Kernel | Debian 13 `linux-image-arm64` (6.12 LTS), ACPI and device tree |
| Consoles | screen (`tty0`) and the PL011 UART (`ttyAMA0`, 115200 8N1); GRUB writes to the firmware's serial port (`serial efi0`) |
| Slot size | 4 GiB (`base`); no `nvidia` variant |
| Disk | GPT: `FLOCKOS` (ESP, 256 MiB), `rootfs-a` (type root-arm64); `rootfs-b` and `data` made on the first boot |
| Firmware updates | fwupd (lane 3) where the board's firmware publishes UEFI capsules |

## Tested hardware

| Board | UEFI version | Date | Result | Notes |
|-------|--------------|------|--------|-------|
| QEMU virt + AAVMF (CI) | Ubuntu 24.04 `qemu-efi-aarch64` | every pull request | `image-test`, `install-test` | arm64 runner without KVM: emulated (TCG) |

## Notes

- CI builds the image natively on GitHub's arm64 runner (`ubuntu-24.04-arm`).
  A local build on an Apple silicon Mac is native too.
- The image test boots it on QEMU's `virt` machine. That machine has one UART,
  so the test's root shell runs on a virtio console (`hvc0`), not a second
  serial port.
- A board whose console is not a PL011 still shows the console on the screen;
  add its `console=` to `FLOCKOS_CMDLINE` in `grubenv` for a serial login.
- GRUB's serial terminal is `serial_efi0` (the firmware's Serial I/O port);
  `GRUB_TERMINAL` in `target.conf`.
- The installer stick (`just build arm64-efi installer`) works as on amd64-efi
  ([amd64-efi.md](amd64-efi.md#installer-stick)): it carries `base` and
  `base-rt`, writes the one `installer.conf` names to an internal disk and
  registers `\EFI\BOOT\BOOTAA64.EFI` as the boot entry.
