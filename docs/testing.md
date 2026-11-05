# Testing FlockOS

Three layers, from fast to slow. The first two run on every pull request and
are required by `ci-ok`; the third is a written checklist per target, because
CI has no GPU, no Raspberry Pi and no Jetson.

| Layer | Command | Where |
|-------|---------|-------|
| unit | `just test` (bats, `test/unit/`) | `gate` job |
| image in QEMU | `just qemu-test TARGET VARIANT` (`test/qemu/run.py`) | `image-test` job, under KVM |
| hardware | the checklist below | a person with the device, evidence attached to the work-package issue |

## Unit tests

`test/unit/*.bats` cover the build library (`build/lib.sh`: configuration
parsing that never runs code, templates without holes, sizes, the matrix axes),
the os-release contract, the target templates (GRUB A/B contract, RAUC
`system.conf`, slot sizes) and the image's own scripts in
`overlay/usr/lib/flockos` run against a temporary directory. They need bash and
bats only:

```sh
just test
```

## Image tests in QEMU

`test/qemu/run.py` takes the artefacts of `just build` from `out/`, copies the
disk image, grows the copy to 20 GiB and boots it with UEFI firmware (OVMF). The
image is the shipped one; the only change to the copy is one value in its
`grubenv`, `FLOCKOS_CMDLINE=systemd.debug_shell=ttyS1`, which gives a root shell
on the second serial port. The script drives that shell; the first serial port
(kernel and systemd console) is written to `console.log`. Because `grubenv` is on
the FLOCKOS partition, the shell is there on both slots, also after an update.

Sequence:

1. **First boot.** System state `running`; os-release carries the image id;
   `systemd-repart` created `rootfs-b` (same size as `rootfs-a`) and `data` (grown
   to the disk); `/data` and its bind mounts are in place; machine-id
   initialised; SSH host keys on `/data` and none in `/etc/ssh`; `sshd` refuses
   root and passwords; no account has a password; RAUC reports slot A booted with
   the right compatible; Docker's data-root is on `/data` and, with
   `--docker-image-tar`, `hello-world` runs; `fwupdmgr` answers. With the test
   `.flock` the harness puts on the FLOCKOS partition (a throwaway key, useless to
   the platform; `--no-flock` leaves it out) the slot is enrolled: SSH user, sudo
   rule and agent unit exist, the `.flock` has left the FLOCKOS partition and the
   agent's copy is 0600.
2. **Reboot.** machine-id, SSH host key and the persistent journal survive.
3. **Update into slot B** with the bundle of the same build, downloaded over
   HTTP from the host as the agent will: RAUC makes B primary, B boots, is marked
   good, keeps machine-id, host key and `/data`, and is enrolled again from the
   agent's copy (SSH user and agent unit back in the new slot).
4. **Fallback.** With `flockos.no-mark-good` added, a second update makes A
   primary; A boots once with `A_TRY=1` and is never marked good; the next boot
   falls back to B.

Locally (Linux with KVM, or slowly under emulation elsewhere) after a build:

```sh
just qemu-test amd64-efi base --keep
```

It needs `qemu-system-x86_64`, OVMF and `mtools`. `--only boot` stops after the
reboot, `--only update` after the update. On failure the work directory with
`console.log` and `shell.log` is kept; in CI both are uploaded as the
`qemu-logs-*` artifact.

## Hardware checklist

Per target, recorded in `docs/targets/<target>.md` with the board model and its
firmware version, and attached to the hardware work package (WP-1.9, WP-4.2,
WP-4b.2, WP-5.4, WP-6.6):

1. Flash the CI-built image (or the release image) with FlockFlasher onto the
   boot medium, with a `.flock` file once Phase 2 enrollment is in.
2. First boot reaches a login prompt on the screen and on the serial console
   where the board has one; `lsblk` shows `FLOCKOS`, `rootfs-a`, `rootfs-b`,
   `data`, the last grown to the medium.
3. Wired network comes up with DHCP; WiFi with a NetworkManager profile where
   the board has WiFi.
4. `docker run --rm hello-world` works.
5. `rauc status` shows the booted slot good.
6. Update to the next build's bundle, reboot, slot switched; break the new slot
   (`flockos.no-mark-good`), update again, confirm the fallback.
7. `fwupdmgr get-devices` lists the board's devices; note which have firmware on
   LVFS.
8. Target-specific items in `docs/targets/<target>.md`.
