# Testing IronFlockOS

Three layers, from fast to slow. The first two run on every pull request and
are required by `ci-ok`; the third is a written checklist per target, because
CI has no GPU, no Raspberry Pi and no Jetson.

| Layer | Command | Where |
|-------|---------|-------|
| unit | `just test` (bats, `test/unit/`) | `gate` job |
| image in QEMU | `just qemu-test TARGET VARIANT` (`test/qemu/run.py`) | `test-<image>` jobs (`qemu-test.yml`), each after its own image, under KVM |
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
`system.conf`, slot sizes), `build/bake.sh` against a fake download base (the
pinned `ironflock`, its signature, what `ironflock bake` must leave), and the
image's own scripts in `overlay/usr/lib/ironflockos` run against a temporary
directory, the enrolment with a fake `ironflock` that ends with each of its
exit codes. The factory reset
(`factory-reset.bats`) runs against folders that stand for the data partition
and the root slots, with fakes for `mount`, `mkfs.ext4`, `lsblk`, `blkid`,
`findmnt`, `grub-editenv`, `sync` and `timeout`: a power loss at each call of
them, a command that does not end, failed steps through folders that take no
new files, and, where `mawk` is installed, Debian's awk. Each failure path
shows that the boot goes on, that the attempt is counted (three, then the
reset gives up), and what the record says.
The network profiles (`network-profiles.bats`) run against folders that stand
for the IRONFLOCKOS partition and `/data/network/connections`, with every rule a
profile has to meet. They need bash and bats only:

```sh
just test
```

## Image tests in QEMU

`test/qemu/run.py` takes the artefacts of `just build` from `out/`, copies the
disk image, grows the copy to 20 GiB (32 GiB for `nvidia`) and boots it with UEFI firmware (OVMF). The
image is the shipped one; the only change to the copy is one value in its
`grubenv`, `IRONFLOCKOS_CMDLINE=systemd.debug_shell=ttyS1`, which gives a root shell
on the second serial port (on arm64 `hvc0`, a virtio console: QEMU's `virt`
machine has one UART). The script drives that shell; the first serial port
(kernel and systemd console) is written to `console.log`. Because `grubenv` is on
the IRONFLOCKOS partition, the shell is there on both slots, also after an update.

With `--secure-boot` the firmware is the build with Microsoft's keys enrolled
and Secure Boot on (`OVMF_CODE_4M.secboot.fd` with `OVMF_VARS_4M.ms.fd` on q35
with SMM; `AAVMF_CODE.ms.fd` with `AAVMF_VARS.ms.fd`), as PCs ship (ADR-0011).
CI boots that way in every image test except the `-rt` ones, which keep the path
with Secure Boot off tested, in both install tests and in `release.yml`'s
`e2e` (below).

Sequence:

1. **First boot.** System state `running`; os-release carries the image id; the
   IRONFLOCKOS partition boots the image's own shim, MokManager and Debian's signed
   GRUB (byte for byte the packaged files), without shim's fallback; shim's MOK
   table reached the kernel (`MOKvar=` in its EFI boot line), and Secure Boot
   is what the test asked for, by the kernel's boot log and `mokutil --sb-state`
   (not on `-rt` kernels, which turn EFI runtime services off); with it on, the
   kernel is locked down in integrity mode;
   `systemd-repart` created `rootfs-b` (same size as `rootfs-a`) and `data` (grown
   to the disk); `/data` and its bind mounts are in place, `/apps` the bind mount
   of `/data/apps` with Docker and the agent ordered after it and
   `ironflockos-apps-check` content, and an app's file is written there; machine-id
   initialised; SSH host keys on `/data` and none in `/etc/ssh`; `sshd` refuses
   root and passwords; no account has a password; RAUC reports slot A booted with
   the right compatible, tried and not marked good by anything at boot (the
   test then marks it, as the device-agent does once it reaches the platform;
   the test `.flock`'s agent never does); Docker's data-root is on `/data` and, with
   `--docker-image-tar`, `hello-world` runs; `fwupdmgr` answers. With the test
   `.flock` the harness puts on the IRONFLOCKOS partition (a throwaway key, useless to
   the platform; `--no-flock` leaves it out) the slot is enrolled: SSH user, sudo
   rule and agent unit exist, the hostname is the `.flock`'s name, the `.flock` has
   left the IRONFLOCKOS partition and the agent's copy is 0600.
   Then `ironflock` (IronFlock/ironflock-cli) in the image: it is
   `/usr/bin/ironflock`, nothing named `ironflock-init` is left, and
   `ironflock version` is the `ironflock_version` of `image.json`;
   `ironflock status --json` names the image, its version and the booted slot
   and, enrolled, the agent with the `.flock`'s device; `agent install` and
   `agent remove` refuse (exit code 3), as root and not; `ironflock enroll` does
   not accept a `.flock` that is not JSON (exit code 4) and leaves it where it
   is; none of them changes anything. Enrolled, the same file as the newest
   `.flock` on the IRONFLOCKOS partition is kept as `.rejected` and the
   enrolment takes the agent's copy; `agent configure -c` refuses while a
   factory reset is requested and with a proxy flag.
   Then `ironflock os` on the device as it was written (WP-5.2 and WP-5.3 of
   the CLI's plan; slot A runs and is good, slot B holds nothing):
   `ironflock os rollback --yes` refuses with exit code 3 and says that slot B
   holds no system yet, and with `--json` the error object on stdout is of
   the kind `precondition`; grubenv and RAUC's slots are as they were, and
   GRUB would start slot A. `ironflock os update --yes --download-base
   <the test host>` reads the test catalog (below, "What `os update`
   needs") and refuses it with exit code 1, the catalog refused for its
   signature (with `--json` an error of the kind `failed`); the host was
   asked for the catalog once per run and for nothing else,
   `/var/cache/ironflockos` keeps no bundle and no copy of the catalog, and
   the slots are as they were. Then the device changes
   hands: its owner, logged in over SSH, runs `sudo ironflock agent configure -c`
   with the `.flock` of another owner; the command outlives the owner's session,
   which it ends, and the device is the other device (the agent's copy, the
   hostname, the other owner's account and sudo rule; the first owner's are
   gone). Configured back as root, it goes on as the first device.
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
   Then a network profile ([ADR-0016](adr/0016-network-profiles-from-the-ironflockos-partition.md)):
   a profile for a static address, the address, gateway and DNS server the VM
   has from DHCP on its card matched by MAC address, as `ironflock os install`
   writes one, goes to the IRONFLOCKOS partition's `network/` folder, and
   `network-profiles check` accepts it.
2. **Reboot.** machine-id, SSH host key, the persistent journal and the app's
   file in `/apps` survive. On
   an `-rt` image (`--kernel rt`) the kernel reports `PREEMPT_RT` first, a new
   `rt.conf` reaches grubenv through `ironflockos-rt-tuning`, and after the reboot
   `isolcpus`, `nohz_full` and `irqaffinity` are on the kernel command line.
   The `proxy.conf` put on the IRONFLOCKOS partition before the reboot has replaced
   the device's (mode 0600) and left the partition, and Docker uses it; the test
   then removes the proxy. The network profile has left the partition for
   `/data/network/connections` (mode 0600, root's), and NetworkManager runs the
   card on it: the address without DHCP's `dynamic` flag, the default route
   through the gateway, and the host still answers. The profile is on trial
   (`ironflockos-network-profiles-trial` runs); the test writes the agent's mark of
   a connection, which its own agent never earns, and the trial ends with the
   profile kept. It stays for the rest of the test (QEMU's DHCP would hand out
   the same address).
3. **Update into slot B** with the bundle of the same build, downloaded over
   HTTP from the host as the agent will: RAUC makes B primary, B boots, keeps
   machine-id, host key, `/data` and the app's file of slot A in `/apps`, and is
   enrolled again from the agent's copy
   (SSH user and agent unit back in the new slot); the test marks B good, in
   the agent's place.
   `rauc install` runs in the background. As soon as RAUC reports on D-Bus
   that it installs (its property `Operation` is `installing`), `rauc status`,
   `ironflock os rollback --yes` and `ironflock os update --yes` (each also
   with `--json`) run back to back, and RAUC is asked again. When it was
   installing before and after them, both `ironflock` commands must refuse
   with exit code 3 and say that RAUC is installing an update right now
   (with `--json` an error of the kind `precondition`). An installation that
   ended during them leaves them kept but not judged, which the log says.
   Once installed, before the restart, `ironflock os rollback` refuses the
   update that waits for its restart (exit code 3, "chosen to start with the
   next restart", text and `--json`), changes nothing, and GRUB would start
   slot B.
4. **Rollback** (`ironflock os rollback`, WP-5.3 of the CLI's plan), under
   KVM only: under emulation, on the arm64 runners, its two restarts would
   take many minutes, and only the refusals run there. On slot B, good, with
   slot A holding the system the image was written with (nothing installed
   into it, so the command takes it even when it was tried since it was
   last marked good, as it usually is here), `ironflock os rollback --yes`
   restarts the device into slot A. Its output and exit code go to files on `/data`,
   synced before the restart, and are read once the device runs again (the
   test's shell answers early in the boot, before `/data` is mounted): exit
   code 0 (from the file, else as the shell printed it before the restart;
   when neither got out, the log says so and the result decides) and
   "Rolled back to IronFlockOS <version> in slot A". The device is up on slot
   A and answers the test host; machine-id, host key, `/data`, the app's file
   in `/apps` and the enrolment are those of before; RAUC's record of the
   update in slot B is unchanged; grubenv has A first in `ORDER` and B still
   good behind it; `ironflock status --json` reports slot A and the image's
   version. The test marks A good in the agent's place
   (`ironflockos-slot-keep` may have been first), and A's `slot-proven`
   mark is there exactly when it was before the rollback (read with
   `debugfs` from slot B). Then `ironflock os rollback --yes --json` takes the
   device forward to slot B the same way: its result is `action`
   `rolled_back`, `slot` B, `from_slot` A and the build's version as
   `version` and `from_version`; the same checks hold with the slots
   swapped, and after B is marked good, `ironflock status --json` reports B
   as booted and primary slot. Both slots hold this build, so the versions
   are the same: the slot tells the systems apart. Whether the agent reaches
   IronFlock again after a rollback (the plan's acceptance) cannot be seen
   in QEMU, where no platform answers: that is left to the hardware test
   (WP-5.7 of the CLI's plan).
5. **Factory reset** ([ADR-0015](adr/0015-factory-reset-requested-on-the-ironflockos-partition.md)).
   On slot B, with slot A holding the system it was updated from: a container
   runs with a restart policy (its image is made in the VM from `sleep` and the
   libraries it links, as the harness has no registry), an app's file is in
   `/apps`, and the site has a network profile and a `proxy.conf`. The test
   writes `factory-reset.conf` with `keep-network=yes` and a new `.flock` (another
   owner and name) to the IRONFLOCKOS partition, each under a temporary name and
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
   proven before, is marked good again by `ironflockos-slot-keep`. Then the same
   request is put back as it was (content and time, as when the IRONFLOCKOS
   partition could not remove it) and the device restarts once: the reset is
   not done again, the journal says so, and the device keeps its machine-id
   and new identity. With `--no-flock` the device stays unenrolled, with the
   hostname `ironflockos`. A failure of the step prints the units the reset touches
   (`systemctl status`, their journal), the reset's record and state, the
   IRONFLOCKOS partition and the reset's lines from the serial console.
6. **Fallback.** A second update makes A primary; A boots once with `A_TRY=1`
   and nobody marks it good (as when the agent cannot reach the platform after
   an update); the next boot falls back to B. `ironflock os rollback` then
   refuses slot A, which was tried and not marked good (exit code 3, "which
   did not start successfully", text and `--json`), changes nothing, and GRUB
   would start slot B.
7. **Crash without a connection.** With a proven system in slot B and a good one
   in slot A, slot B stays up until it has marked itself good, and the kernel
   is crashed on purpose (`/proc/sysrq-trigger`). The device restarts by itself
   on slot B and the kernel's record of the crash is under `/data/pstore`,
   except on an `-rt` image, which has no EFI runtime services to record it in.
   A second crash right after that boot, before the slot has stayed up for two
   minutes, counts as a failed try: the device comes up on slot A.

**Install test** (`--variant installer`, the `install-test-<target>` jobs, for amd64-efi
under KVM and arm64-efi emulated): the installer image is attached as a USB stick with `installer.conf` set to
`payload=ironflockos-<target>-base` (the stick carries every image of its target)
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
`arm64-efi`), `mtools` and OpenSSL 3 (the test catalog's Ed25519 key and
signature). The VM runs under KVM where the host has it and the
architectures match, under Hypervisor.framework for `arm64-efi` on an Apple
silicon Mac, and emulated otherwise (much slower; CI's arm64 runners have no
KVM). `--only boot` stops after the
reboot, `--only update` after the update. On failure the work directory with
`console.log`, `shell.log` and `captured/` is kept; in CI they are uploaded as
the `qemu-logs-*` artifact.

**What `ironflock` reads and prints.** The `ironflock os` steps keep the real
output of what the CLI parses and prints in `captured/` of the work
directory, so that the CLI's fixtures (`cli/ironflockos/testdata/` and the
tests of `os update` and `os rollback` in IronFlock/ironflock-cli), made up
from RAUC's sources so far, can be replaced by it. One file per command:
`<NN>-<state>--<name>.json`, numbered in the order they ran, with `command`
(the command line as the CLI's `commands.json` keys it, its words joined by
spaces), `exit` (`null` when a command restarted the device before the shell
could write it), `stdout` and `stderr`; and the files the CLI reads as they
are (`--grubenv`, `--system.conf`, `--os-release`). The states:

| State | The device |
| --- | --- |
| `fresh` | as written: slot A runs and is good, slot B holds nothing |
| `busy` | RAUC installs into slot B: `rauc status`, `os rollback` and `os update` asked meanwhile |
| `install` | the output of `rauc install` that ended well |
| `pending` | the update is installed in slot B and waits for the restart |
| `updated` | slot B runs the update and is good; slot A holds the image's system |
| `rolled-back` | after `os rollback`, slot A runs again, before the test marks it good |
| `rolled-forward` | after the second `os rollback`, slot B runs again and is good |
| `fell-back` | slot A was tried and not marked good; slot B runs |

`rauc status --detailed --output-format=json`, `grubenv` and `ironflock
status --json` are kept in every state; `debugfs -c -R cat /usr/lib/os-release
/dev/disk/by-partlabel/rootfs-a` (the version of the image in slot A, as the
CLI reads it) when slot B runs. They hold no secret: the test `.flock` is a
throwaway, and the test catalog's key stays in the work directory, which is
not uploaded. The `rolled-back` and `rolled-forward` states are missing under
emulation.

**What `os update` needs.** WP-5.2 of the CLI's plan asks for an update with
`ironflock os update --reboot --yes` that boots the new slot. That needs a
catalog the image's `ironflock` accepts and a bundle the image's keyring
accepts. A pull request's images trust a throwaway CA of their own build
(`build/signing.sh`), so only their own bundle installs; the `ironflock` they
carry is a release (`profiles/base/versions`, checked against the bootstrap
key by `build/bake.sh`), and a release trusts IronFlock's catalog key alone,
compiled in, with no flag or variable to add another. So the test serves a
catalog of its own (`put_test_catalog` in `run.py`): made after
`docs/manifest.schema.json`, naming the next patch release above `VERSION`
in both channels, with this build's image and bundle (their sizes and
SHA-256) for the image under test, signed with an Ed25519 key made for the
run, and the bundle below it at `ironflockos/<release>/`, as a download base
serves them. Today the image's `ironflock` refuses that catalog (step 1). The
update itself, its restart into slot B and what `ironflock` reports after it
wait for an `ironflock` that also trusts a key the test gives it, which
releases never do (the open point of WP-0.5 in the CLI's plan); with one, the
test would put it on `/data` and run it there against the same catalog.
Until then the update into slot B is RAUC's own, as before.

**When an update or a rollback fails.** A device must still boot and come
online (the lifeline rule). The test checks what it can see of that:
every refused `ironflock os` command leaves grubenv and RAUC's slots as they
were, and GRUB's next slot (by `grub.cfg`'s rule) is the one that runs, or the
installed update that waits; a refused update has downloaded and kept
nothing; after each rollback the device is up and answers the test host.

**The release images.** The tests above run on development builds, which
trust a throwaway CA of their own build. A release pull request also runs
`release.yml` as a dry run, which builds the release images (they trust the
IronFlockOS root CA) and boots the one of `amd64-efi base` in its `e2e` job
with `--only boot`: its bundle carries the dry run's stand-in signature,
which a release image refuses, so the update and every step after it cannot
run. The other release images are not booted at all. Every test runs before
the merge ([ADR-0019](adr/0019-every-test-runs-before-the-merge.md)): the
release run that reuses those images does not test them again; its `sign`
job checks each bundle with `rauc info` against the keyring and RAUC
settings in slot A of its image, without a VM and without an install. Only a
release run that has to build its images runs `e2e` in full on its image of
`amd64-efi base`, with its own KMS-signed bundle, before it publishes.

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
   where the board has one; `lsblk` shows `IRONFLOCKOS`, `rootfs-a`, `rootfs-b`,
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
    `.flock` on the IRONFLOCKOS partition, restart. The screen shows the reset's
    steps, the device restarts by itself, comes back on the same slot and WiFi,
    enrolls as the new device and runs no app of the old one;
    `factory-reset.log` says `result=done`. Then with an empty
    `factory-reset.conf` and no `.flock`: the device comes up unenrolled.
11. Network profiles (`docs/build.md`, "Network profiles"), where the board has
    WiFi: flash with a `.flock` without WiFi and a WPA-PSK profile in `network/`
    on the IRONFLOCKOS partition, with the wired network unplugged. The device
    joins that WiFi on its first boot and enrolls; the profile has left the
    partition.
12. Target-specific items in `docs/targets/<target>.md`.
