# Target amd64-efi

UEFI x86 edge PCs and industrial PCs (master plan, sections 3.2 and 3.7).

| | |
|---|---|
| Boot | UEFI only (no legacy BIOS). Debian's shim (signed by Microsoft) at the removable-media path `EFI/BOOT/BOOTX64.EFI`, Debian's signed GRUB next to it; boots with Secure Boot on or off (ADR-0011) |
| A/B | RAUC `grub` backend, `grubenv` on the IRONFLOCKOS partition, `rauc.slot=` on the kernel command line |
| Kernel | Debian 13 `linux-image-amd64` (6.12 LTS), `amd64-microcode`, `intel-microcode`; `-rt` images: `linux-image-rt-amd64` (PREEMPT_RT) with `ironflockos-rt-tuning` |
| Firmware blobs | `firmware-linux-free`, `firmware-misc-nonfree`, `-realtek`, `-iwlwifi`, `-atheros`, `-brcm80211`, `-mediatek`; for Intel graphics and audio `firmware-intel-graphics` and `firmware-sof-signed` (Debian 13 moved them out of `firmware-misc-nonfree`) |
| Consoles | screen (`tty0`) and first serial port (`ttyS0`, 115200 8N1) |
| Slot size | 4 GiB (`base`), 8 GiB (`nvidia`) |
| Disk | GPT: `IRONFLOCKOS` (ESP, 256 MiB), `rootfs-a`; `rootfs-b` and `data` made on the first boot |
| Watchdog | systemd uses a hardware watchdog when the board has one (60 s) |
| Firmware updates | fwupd (lane 3); board UEFI only where the vendor publishes capsules (section 3.10) |
| GPU (`nvidia`) | NVIDIA driver from the CUDA repository with the open kernel modules: Turing (RTX 20, T4) and newer; older GPUs need the proprietary modules, which IronFlockOS does not ship. Containers get the GPU through the `nvidia` runtime (`docker run --gpus all`) or CDI. Needs Secure Boot off (see below) |

## Tested hardware

| Board | UEFI version | Date | Result | Notes |
|-------|--------------|------|--------|-------|
| QEMU q35 + OVMF (CI) | Ubuntu 24.04 `ovmf` | every pull request | `image-test`, `install-test` | KVM on GitHub runners; `base` and `nvidia` (no GPU); Secure Boot on with Microsoft's keys (`OVMF_VARS_4M.ms.fd`), off for `base-rt` |

Hardware entries are added by WP-1.9 (`docs/testing.md`, hardware checklist).

## Notes

- Boot from USB: the image boots from the removable-media path, so no boot entry
  is needed; on boards that hide USB boot, enable it in the firmware setup.
- Secure Boot (ADR-0011): leave it as the machine came. IronFlockOS boots with
  Microsoft's keys, as Windows and Debian do; `mokutil --sb-state` shows the
  state (on `-rt` images, whose kernel turns EFI runtime services off,
  `cat /sys/kernel/security/lockdown`: `[integrity]` with Secure Boot on).
  Two exceptions:
  - Some Windows "Secured-core" PCs ship without the Microsoft third-party UEFI
    CA, which signed shim. The firmware then refuses the disk; switch on
    "Allow Microsoft 3rd party UEFI CA" (the name varies) or turn Secure Boot off.
  - `nvidia`: the NVIDIA kernel modules are not signed with a key the machine
    trusts, so with Secure Boot on the GPU stays unused and the console says so
    at boot (`journalctl -u ironflockos-nvidia-secure-boot`). Turn Secure Boot off to
    use the GPU.
- Disks flashed with a release before ADR-0011 have an unsigned boot loader and
  keep it through updates: they need Secure Boot off, or a new flash.
- Some IPC firmware enables a hardware watchdog in setup; IronFlockOS feeds it from
  systemd once booted.
- `nvidia` on a GPU host (WP-4.2): `nvidia-smi` on the host and
  `docker run --rm --gpus all nvidia/cuda:<version>-base-ubuntu24.04 nvidia-smi`
  in a container, before and after an A/B update between two `nvidia` builds.

## Installer stick

For sealed IPCs that cannot boot a USB-flashed system disk. The stick carries
every amd64-efi image: `base`, `base-rt` and `nvidia`. In FlockFlasher choose
the hardware, the IronFlockOS variant, and "Installer stick" as the way to
install: it writes the stick, the `.flock` and an `installer.conf` that names
the variant (`payload=<image id>`) to its IRONFLOCKOS partition. Boot the IPC from
the stick (8 GB or larger: the image is 5.3 GiB). Example for an NVIDIA box
with one NVMe and no keyboard:

```ini
# installer.conf
payload=ironflockos-amd64-efi-nvidia
disk=largest
confirm=no
after=poweroff
```

Without `confirm=no` the installer asks on the console before it writes.

The installer leaves out the stick itself, read-only, loop and too-small disks,
and USB disks unless `allow-usb=yes`. When it is done the box powers off; remove
the stick and power on. Hardware acceptance is WP-3.3.

## Real-time latency

The figure per hardware class comes from `cyclictest -m -Sp99 -i200 -h400` for
one hour under Docker load on the isolated CPUs (WP-4b.2), with C-states and
SMIs set as noted. QEMU only proves that the `-rt` image boots and applies its
tuning.

| Board | Firmware settings | Isolated CPUs | Max latency | Date |
|-------|-------------------|---------------|-------------|------|
| — | — | — | — | — |

## Compute Engine

Every release makes Compute Engine images of `base` and `nvidia` for the
virtual-device-manager's IronFlockOS VMs, in the image families
`ironflockos-amd64-efi-base` and `ironflockos-amd64-efi-nvidia` of `record-1283`
([ADR-0010](../adr/0010-ironflockos-images-for-virtual-devices.md)). They are the
release images as published: GCE's serial port 1 is `ttyS0`, the disk is
virtio-scsi or NVMe, the NIC virtio-net or gVNIC. `nvidia` runs on G2 (L4) and
on N1 with a T4. A VM gets its `.flock` from the instance metadata
(`ironflockos-gce-flock.service`). The smallest disk is 10 GiB for `base` and 18 GiB
for `nvidia`.
