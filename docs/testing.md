# Testing IronFlockOS

Three layers, from fast to slow. The first two run on every pull request and
are required by `ci-ok`; the third is a written checklist per target, because
CI has no GPU, no Raspberry Pi and no Jetson.

| Layer | Command | Where |
|-------|---------|-------|
| unit | `just test` (bats, `test/unit/`) | `gate` job |
| image in QEMU | `just qemu-test TARGET VARIANT` (`test/qemu/run.py`) | `image-test` job, under KVM |
| hardware | the checklist below | a person with the device, evidence attached to the work-package issue |

Next to these, `security.yml` scans the packages of every image, through the
harness's `rootfs-recipe` input, on pull requests and every Monday. The harness
runs `just rootfs TARGET VARIANT KERNEL` once per image; it builds the root tree
in `ROOTFS_WORK`, without a disk image. Then `trivy rootfs` writes:

- the vulnerabilities with a fix, as SARIF, which `security / report` counts
  and code scanning shows (category `rootfs-<image>`);
- the CycloneDX SBOM of all packages, as the artifact
  `security-rootfs-sbom-<image>`.

Accepted findings go into `security/vex.openvex.json` or `.trivyignore.yaml`
with a reason and an expiry date.

## Unit tests

`test/unit/*.bats` cover the build library (`build/lib.sh`: configuration
parsing that never runs code, templates without holes, sizes, the matrix axes),
the os-release contract, the target templates (GRUB A/B contract, RAUC
`system.conf`, slot sizes) and the image's own scripts in
`overlay/usr/lib/flockos` run against a temporary directory. The factory reset
(`factory-reset.bats`) runs against folders that stand for the data partition
and the root slots, with fakes for `mount`, `mkfs.ext4`, `lsblk`, `blkid`,
`findmnt`, `grub-editenv` and `sync`, a power loss at each call of them, failed
steps through folders that take no new files, and, where `mawk` is installed,
Debian's awk. The network profiles (`network-profiles.bats`) run against
folders that stand for the FLOCKOS partition and `/data/network/connections`,
with every rule a profile has to meet. They need bash and bats only:

```sh
just test
```

## Image tests in QEMU

`test/qemu/run.py` takes the artefacts of `just build` from `out/`, copies the
disk image, grows the copy to 20 GiB (32 GiB for `nvidia`) and boots it with UEFI firmware (OVMF). The
image is the shipped one; the only change to the copy is one value in its
`grubenv`, `FLOCKOS_CMDLINE=systemd.debug_shell=ttyS1`, which gives a root shell
on the second serial port (on arm64 `hvc0`, a virtio console: QEMU's `virt`
machine has one UART). The script drives that shell; the first serial port
(kernel and systemd console) is written to `console.log`. Because `grubenv` is on
the FLOCKOS partition, the shell is there on both slots, also after an update.

With `--secure-boot` the firmware is the build with Microsoft's keys enrolled
and Secure Boot on (`OVMF_CODE_4M.secboot.fd` with `OVMF_VARS_4M.ms.fd` on q35
with SMM; `AAVMF_CODE.ms.fd` with `AAVMF_VARS.ms.fd`), as PCs ship (ADR-0011).
CI boots that way in every image test except the `-rt` ones, which keep the path
with Secure Boot off tested, in both install tests and in the release's
end-to-end test.

Sequence:

1. **First boot.** System state `running`; os-release carries the image id; the
   FLOCKOS partition boots the image's own shim, MokManager and Debian's signed
   GRUB (byte for byte the packaged files), without shim's fallback; shim's MOK
   table reached the kernel (`MOKvar=` in its EFI boot line), and Secure Boot
   is what the test asked for, by the kernel's boot log and `mokutil --sb-state`
   (not on `-rt` kernels, which turn EFI runtime services off); with it on, the
   kernel is locked down in integrity mode;
   `systemd-repart` created `rootfs-b` (same size as `rootfs-a`) and `data` (grown
   to the disk); `/data` and its bind mounts are in place, `/apps` the bind mount
   of `/data/apps` with Docker and the agent ordered after it and
   `flockos-apps-check` content, and an app's file is written there; machine-id
   initialised; SSH host keys on `/data` and none in `/etc/ssh`; `sshd` refuses
   root and passwords; no account has a password; RAUC reports slot A booted with
   the right compatible, tried and not marked good by anything at boot (the
   test then marks it, as the device-agent does once it reaches the platform;
   the test `.flock`'s agent never does); Docker's data-root is on `/data` and, with
   `--docker-image-tar`, `hello-world` runs; `fwupdmgr` answers. With the test
   `.flock` the harness puts on the FLOCKOS partition (a throwaway key, useless to
   the platform; `--no-flock` leaves it out) the slot is enrolled: SSH user, sudo
   rule and agent unit exist, the hostname is the `.flock`'s name, the `.flock` has
   left the FLOCKOS partition and the agent's copy is 0600.
   For `nvidia`, on a VM without a GPU: the `nvidia` module and the driver
   packages are at the pinned versions and the module is built for the running
   kernel; no compiler, DKMS or kernel headers are left; nouveau is blacklisted
   in the initramfs; neither nouveau nor nvidia is loaded and
   `nvidia-persistenced` is not enabled; Docker lists the `nvidia` runtime;
   `nvidia-ctk` and `nvidia-container-cli` run.
   Then the time: chrony runs and systemd-timesyncd is gone; a `ptp.conf` that
   names the VM's interface gives chrony a PTP source and starts `ptp4l` and
   `phc2sys`; `role=server` gives `ptp4l` the master's settings and takes the
   source away; removing the file stops them. QEMU's interface has no hardware
   time stamps, so this checks the wiring; PTP itself is on the hardware
   checklist.
   Then the proxy: a `proxy.conf` reaches Docker (`docker info` names the proxy,
   and `NO_PROXY` holds `localhost` and the file's `no_proxy`), the agent's
   environment while it runs, and chrony (`ntp=`); `proxy.env` is readable by
   root only. Nothing listens on the proxy address: a real proxy is on the
   hardware checklist.
   Then a network profile ([ADR-0016](adr/0016-network-profiles-from-the-flockos-partition.md)):
   a profile for a static address, the address, gateway and DNS server the VM
   has from DHCP on its card matched by MAC address, as `ironflock os install`
   writes one, goes to the FLOCKOS partition's `network/` folder, and
   `network-profiles check` accepts it.
2. **Reboot.** machine-id, SSH host key, the persistent journal and the app's
   file in `/apps` survive. On
   an `-rt` image (`--kernel rt`) the kernel reports `PREEMPT_RT` first, a new
   `rt.conf` reaches grubenv through `flockos-rt-tuning`, and after the reboot
   `isolcpus`, `nohz_full` and `irqaffinity` are on the kernel command line.
   The `proxy.conf` put on the FLOCKOS partition before the reboot has replaced
   the device's (mode 0600) and left the partition, and Docker uses it; the test
   then removes the proxy. The network profile has left the partition for
   `/data/network/connections` (mode 0600, root's), and NetworkManager runs the
   card on it: the address without DHCP's `dynamic` flag, the default route
   through the gateway, and the host still answers. The profile is on trial
   (`flockos-network-profiles-trial` runs); the test writes the agent's mark of
   a connection, which its own agent never earns, and the trial ends with the
   profile kept. It stays for the rest of the test (QEMU's DHCP would hand out
   the same address).
3. **Update into slot B** with the bundle of the same build, downloaded over
   HTTP from the host as the agent will: RAUC makes B primary, B boots, keeps
   machine-id, host key, `/data` and the app's file of slot A in `/apps`, and is
   enrolled again from the agent's copy
   (SSH user and agent unit back in the new slot); the test marks B good, in
   the agent's place.
4. **Factory reset** ([ADR-0015](adr/0015-factory-reset-requested-on-the-flockos-partition.md)).
   On slot B, with slot A holding the system it was updated from: a container
   runs with a restart policy (its image is made in the VM from `sleep` and the
   libraries it links, as the harness has no registry), an app's file is in
   `/apps`, and the site has a network profile and a `proxy.conf`. The test
   writes `factory-reset.conf` with `keep-network=yes` and a new `.flock` (another
   owner and name) to the FLOCKOS partition, each under a temporary name and
   renamed, as `ironflock os reset -c` does, and `factory-reset check` accepts
   the request. The boot after the restart resets the device and restarts it by
   itself. It comes up on slot B (the reset's restart counted as no failed try),
   with `factory-reset.log` saying `result=done`, the request and the temporary
   files gone, a new machine-id and host key, neither the container nor its
   image nor `hello-world`, no app file or old journal, the old SSH user gone
   and the device enrolled as the new one, the agent's copy of the `.flock` the
   new one; the network profile, `proxy.conf` and RAUC's
   record of slot B are kept; slot A, read with `debugfs`, has the image's
   hostname, `uninitialized` as machine-id and no `enrolled` mark; slot B,
   proven before, is marked good again by `flockos-slot-keep`. With
   `--no-flock` the device stays unenrolled, with the hostname `flockos`.
5. **Fallback.** A second update makes A primary; A boots once with `A_TRY=1`
   and nobody marks it good (as when the agent cannot reach the platform after
   an update); the next boot falls back to B.
6. **Crash without a connection.** With a proven system in slot B and a good one
   in slot A, slot B stays up until it has marked itself good, and the kernel
   is crashed on purpose (`/proc/sysrq-trigger`). The device restarts by itself
   on slot B and the kernel's record of the crash is under `/data/pstore`,
   except on an `-rt` image, which has no EFI runtime services to record it in.
   A second crash right after that boot, before the slot has stayed up for two
   minutes, counts as a failed try: the device comes up on slot A.

**Install test** (`--variant installer`, the `install-test` job, for amd64-efi
under KVM and arm64-efi emulated): the installer image is attached as a USB stick with `installer.conf` set to
`payload=flockos-<target>-base` (the stick carries every image of its target)
and `confirm=no`, and the test `.flock`, next to a blank 20 GiB NVMe. The stick
must install that image to `/dev/nvme0n1` on its own, copy the `.flock` to the
new disk and power off; its log must say all three. The NVMe then boots alone, with the UEFI variables the
installer wrote, passes the first-boot checks above and enrolls with that
`.flock` (`--no-flock` leaves it out).

Locally (Linux with KVM, or slowly under emulation elsewhere) after a build:

```sh
just qemu-test amd64-efi base --keep
```

It needs `qemu-system-x86_64` and OVMF (or `qemu-system-aarch64` and AAVMF for
`arm64-efi`) and `mtools`. The VM runs under KVM where the host has it and the
architectures match, under Hypervisor.framework for `arm64-efi` on an Apple
silicon Mac, and emulated otherwise (much slower; CI's arm64 runners have no
KVM). `--only boot` stops after the
reboot, `--only update` after the update. On failure the work directory with
`console.log` and `shell.log` is kept; in CI both are uploaded as the
`qemu-logs-*` artifact.

## Raspberry Pi image checks

QEMU cannot boot the Pi firmware, so `rpi-arm64` has no image test. CI runs
`sudo test/image/rpi-check.sh <image>.img.gz` on the arm64 runner instead: GPT
layout, `autoboot.txt`, the boot files and `cmdline.txt` of boot-a, slot A's
tree (os-release, units, the RAUC tryboot backend and its slot groups, the
baked agent, no passwords) and the image's own binaries in a chroot. The
backend's logic is covered by `test/unit/rpi-tryboot.bats` against fixture
`autoboot.txt` files and a fake firmware device tree; the update and fallback
on a real Pi is the hardware checklist. It needs root and an arm64 host. The boot itself is
the hardware checklist below (WP-5.4).

## Jetson root tree checks

`jetson-orin` has no disk image of IronFlockOS's own: NVIDIA's flash tools write
its disk (WP-6.2). CI builds slot A's filesystem image and the bundle with
`just build jetson-orin base` on the arm64 runner and runs
`sudo test/image/jetson-rootfs-check.sh <tree>`. The script checks the L4T
packages at the pinned versions, the Ubuntu, Docker and NVIDIA sources with
the pins, kernel, initrd and `nvgpu`, the RAUC slots, units and masks, the
baked agent and Docker's `nvidia` runtime. It also runs the tree's binaries in
a chroot (`docs/targets/jetson-orin.md`). It needs root and an arm64 host.
The `jetson-flash` job then makes the flash package from the image with
NVIDIA's tools on an x86_64 runner (`build/tegra-flash-package.sh`): the dry
run that the layout and the slot images pass the BSP's checks.

Both jobs are switched off for now to save CI time, until the Jetson work
continues. `ci.yml` says how to switch them on.

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
5. `rauc status` shows the booted slot good once the device-agent has reached
   the platform (enrolled with a real `.flock`).
6. Update to the next build's bundle, reboot, slot switched and marked good by
   the agent; update again, keep the device off the network, reboot twice,
   confirm the fallback.
7. `fwupdmgr get-devices` lists the board's devices; note which have firmware on
   LVFS.
8. Where the site uses PTP (`docs/build.md`, "Time"). As a client, `ptp.conf`
   with the interface toward the master: `chronyc sources` shows `#* PTP` within
   a few minutes; with the master's cable unplugged, chrony selects an NTP source
   again. As a server, `role=server` on the interface toward the clients: `pmc`
   shows the device's own `clockIdentity` as `grandmasterIdentity`, and a client
   (a camera, or a second device with `ptp.conf` as a client) reports an offset
   to it of well under a microsecond.
9. Behind a proxy (`docs/build.md`, "Proxy"), on a network that blocks direct
   internet access: flash with a `proxy.conf` next to the `.flock`; the device
   enrolls and the agent reaches the platform; an app's image pulls; an OS
   update downloads and installs; remote access works; `chronyc sources` uses
   the `ntp=` servers.
10. Factory reset (`docs/build.md`, "Factory reset"), on a device on WiFi
    with apps running: `factory-reset.conf` with `keep-network=yes` and a new
    `.flock` on the FLOCKOS partition, restart. The screen shows the reset's
    steps, the device restarts by itself, comes back on the same slot and WiFi,
    enrolls as the new device and runs no app of the old one;
    `factory-reset.log` says `result=done`. Then with an empty
    `factory-reset.conf` and no `.flock`: the device comes up unenrolled.
11. Network profiles (`docs/build.md`, "Network profiles"), where the board has
    WiFi: flash with a `.flock` without WiFi and a WPA-PSK profile in `network/`
    on the FLOCKOS partition, with the wired network unplugged. The device
    joins that WiFi on its first boot and enrolls; the profile has left the
    partition.
12. Target-specific items in `docs/targets/<target>.md`.
