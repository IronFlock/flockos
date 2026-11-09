# ADR-0011: Secure Boot with Debian's signed boot chain

Status: accepted, 2026-11-06.

## Context

Most x86 PCs and industrial PCs ship with UEFI Secure Boot on and Microsoft's keys
enrolled. IronFlockOS 1.x booted a GRUB it built itself (`grub-mkimage`), which nobody
signed, so such a machine refused the disk until someone turned Secure Boot off in
the firmware setup. That is the first thing a user meets, and on a sealed IPC or in a
remote site it is the hardest.

The goal here is convenience: a IronFlockOS disk or installer stick boots on a machine as
it comes from the factory. It is not tamper resistance; that needs IronFlock's own
keys, signed unified kernel images, a verified root and TPM-sealed data (master plan,
section 8), and stays later hardening.

## Decision

The EFI targets (`amd64-efi`, `arm64-efi`, their installer sticks) boot Debian's
signed boot chain:

- **Firmware → shim.** Debian's `shim-signed` (shim 16.1), signed by Microsoft, at the
  removable-media path `EFI/BOOT/BOOTX64.EFI` (`BOOTAA64.EFI`). Debian's shim carries
  two signatures, one under the Microsoft UEFI CA 2011 and one under its 2023
  successor, so it boots on firmware that has either.
- **shim → GRUB.** Debian's `grub-efi-<arch>-signed` as `EFI/BOOT/grub<arch>.efi`,
  which shim checks against Debian's certificate. Its modules are built in. It reads
  `grub.cfg` next to itself first (`$fw_path`, a patch Debian carries), so IronFlockOS's A/B
  script in `/EFI/BOOT` runs as before; a GRUB without that patch reads its prefix,
  `/EFI/debian/grub.cfg`, which sources the same script. `${prefix}` stays
  `/EFI/debian` either way, so the script sets it to `/EFI/BOOT` before it loads
  `grubenv`. The script's slot logic, `grubenv` and their paths are unchanged.
- **GRUB → kernel.** Debian's kernels are signed already (`linux-signed-*`); GRUB has
  shim check them. With Secure Boot on, the kernel runs in lockdown (integrity mode).
- **MokManager** (`mm<arch>.efi`, from `shim-helpers-<arch>-signed`) is next to shim,
  which starts it when a check fails. shim's fallback (`fb<arch>.efi`) is not: it
  writes boot entries and reboots.
- **The binaries are packages of the image** (`targets/<target>/packages`), copied to
  the FLOCKOS partition by `build/mkimage.sh`. `packages.tsv` and the SBOM list them,
  and the weekly rescans see their CVEs. The build container no longer needs
  `grub-efi-<arch>-bin`.
- **fwupd's capsule helper** is Debian's signed one (`fwupd-<arch>-signed`), so capsule
  updates (lane 3) also start under Secure Boot.
  fwupd starts it through shim and looks for shim next to it, in `EFI/debian`, so
  `flockos-fwupd-shim.service` copies the shim the device boots there on every boot. RAUC
  does not write this partition, and it must be that same shim: a newer one could revoke
  the GRUB beside it through SBAT.

The same chain boots with Secure Boot off, without the checks.

## Consequences

- **Factory settings boot.** No firmware setup visit for Secure Boot. Some Windows
  "Secured-core" PCs ship with the Microsoft third-party UEFI CA disabled; on those,
  "Allow Microsoft 3rd party UEFI CA" (or similar) has to be switched on once, or
  Secure Boot off (`docs/targets/amd64-efi.md`).
- **NVIDIA.** The open kernel modules of the `nvidia` variant are built with the image
  and signed by no key the machine trusts. A locked-down kernel refuses them: the
  device boots and enrolls, but the GPU stays unused. `flockos-nvidia-secure-boot`
  says so on the console and in the journal, for each NVIDIA display controller, and
  the GPU needs Secure Boot off. Signing the modules with a key the kernel trusts
  needs a Machine Owner Key or a shim of IronFlock's own (see Alternatives).
- **Not a security boundary.** GRUB's configuration, `grubenv` (including
  `FLOCKOS_CMDLINE` and `FLOCKOS_RT_CMDLINE`), the initramfs and the root filesystem are
  not checked, and any other Microsoft-signed boot loader boots on the same machine.
  That keeps the A/B script, the real-time tuning and the QEMU test's debug shell
  working as before.
- **Devices flashed before this change** keep their unsigned GRUB: RAUC bundles carry
  the root slot, not the FLOCKOS partition. They boot and update as before with Secure
  Boot off. Turning Secure Boot on there takes a new flash or installation.
- **The boot chain is the one of the installation.** Nothing updates the FLOCKOS
  partition in the field yet. If a machine's firmware later revokes that shim or GRUB
  (a `dbx` update, or a newer shim's SBAT level, for example from another system booted
  on it), IronFlockOS stops booting with Secure Boot on until it is turned off or the disk
  is installed again. An update path for the FLOCKOS partition is follow-up work.
- **shim writes its variables.** Like on every Debian system, shim keeps its MOK and
  SBAT state in UEFI variables (`MokListRT`, `SbatLevel`).
- **Tests.** The QEMU tests boot with Microsoft's keys enrolled and Secure Boot on
  (`test/qemu/run.py --secure-boot`): the image tests except the `-rt` ones, which
  keep the path with Secure Boot off tested, the install tests and the release's
  end-to-end test. Every run checks that the FLOCKOS partition holds the packaged shim
  and GRUB and that Secure Boot and lockdown are as asked.
- **Compute Engine.** The release images can now boot Shielded VMs with Secure Boot
  on, as Debian's own Compute Engine images do; that is not tested yet. The
  virtual-device-manager may turn it on for VMs without a GPU; with a GPU it must stay
  off, as on hardware.

## Alternatives

- **IronFlock's own keys and signed unified kernel images**, with systemd-boot and
  RAUC's `efi` backend. The real hardening, but every machine needs its keys enrolled
  (setup mode, per board), the per-device kernel command line of the `-rt` images has
  to go, and the NVIDIA modules still need a key the kernel trusts. Later (master
  plan, section 8); Compute Engine, where an image can carry its own keys, is the
  first place for it.
- **A shim of IronFlock's own, signed by Microsoft**, with IronFlock's certificate
  inside: the NVIDIA modules could be signed and trusted. It needs the shim review
  process, an EV certificate, months of lead time and a standing security response
  duty. Not worth it for convenience.
- **Machine Owner Keys for the NVIDIA modules.** Enrolling one needs someone at the
  console on the next boot, which is no easier than turning Secure Boot off.
- **Leave Secure Boot unsupported.** Every new PC needs a firmware setup visit.
