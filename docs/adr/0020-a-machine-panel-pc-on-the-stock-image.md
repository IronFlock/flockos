# ADR-0020: A machine's panel PC runs the stock image, and its functions move into apps

Status: proposed, 2026-11-12. The first machine was surveyed on 2026-11-12 (section 8).
Built with this record: the repair at boot (section 7) and AppArmor (section 5). The
screen has its own plan ([kiosk-plan.md](../kiosk-plan.md)), and the firewall waits for
the device-agent's feature (section 6).

## Context

The first machine PC to move to IronFlockOS is the panel PC of ADR-0013: an edge PC with a
touch screen, built into a production machine. Today it runs its builder's own Debian 12
image. That image's SBOM lists 909 components, all installed as packages, with a 6.1
PREEMPT_RT kernel, A/B updates through swupdate and no container runtime. The machine is
to run IronFlockOS and the device-agent, with its software as IronFlock apps.

Two sources stand behind this record: the SBOM, compared with
`ironflockos-amd64-efi-base-rt` 0.16.0 (311 Debian packages, kernel 6.12 PREEMPT_RT), and
a read-only survey of one running machine.

**The machine.** An Intel Core i5 of the 11th generation with four cores, 32 GiB of
memory, a 477 GiB SATA SSD, Intel graphics on a built-in 1920x1080 panel, a USB touch
screen, three Intel I226 network cards with hardware time stamps, and a hardware
watchdog. It boots through UEFI, with Secure Boot off. Every device runs on a driver of
Debian's kernel, and Debian's 6.12 configuration has each of these drivers.

**IronFlockOS has it already.**

- The real-time kernel. The machine isolates no CPU; its programs run under SCHED_FIFO
  and SCHED_RR with priorities from 20 to 43, on all CPUs, with the `performance`
  governor. `rt.conf` is there if a CPU set is wanted later.
- A/B updates with fallback, as the machine has with swupdate and two root partitions.
- PTP (ADR-0013). The machine is a PTP client with hardware time stamps on its uplink,
  and runs no NTP service.
- The network. The machine takes its address by DHCP on one interface; static profiles
  (ADR-0016) and the proxy (ADR-0014) are there for other sites.
- Logs and state outside the root slot, key-only SSH, Intel's microcode and firmware, an
  SBOM per image.

**It is not the OS's.** Most of the 909 components are the user space of the machine's
function. About 45 services run: the machine's applications, the X server with a
compositor, a remote view of the screen, a web server, a certificate service, a code
editor, and the .NET, Mono and Node runtimes below them. An app's image brings its own
user space.

**Where the two differ.**

1. Kernel drivers from vendors. The builder's image carries four driver packages for its
   other machine types: for a fieldbus card, for two kinds of CAN interfaces and for a
   vision controller. On the surveyed machine none of their modules is loaded. All four
   modules declare the GPL. One replaces the kernel's own `uio_netx`; for PEAK
   interfaces the image turns the kernel's own drivers off and loads the vendor's.
   IronFlockOS builds modules from outside the kernel for the `nvidia` variant only,
   which has no `-rt` image.
2. A local screen. The machine shows a GUI on its touch panel from the boot on, with a
   boot logo before it. The master plan lists a GUI session as a non-goal.
3. Updates without the platform: swupdate takes them from a web page on the machine.
4. AppArmor. The machine enforces 37 profiles, among them profiles for the web server,
   the remote view and SSH. The IronFlockOS image has no `apparmor` package, and Docker
   puts its `docker-default` profile on containers only where it finds AppArmor's tools.
5. A firewall. The machine drops inbound, forwarded and outbound traffic by default,
   admits listed ports from a list of client addresses, and limits the rate of new
   connections. The list admits every address today. IronFlockOS has `nftables` without
   rules; the master plan (section 3.9) names a closed inbound side as an option that is
   not built yet.
6. Power cuts. The machine's root is read-write ext4, as IronFlockOS's is. It keeps 34
   folders that change while it runs (logs, recipes, home folders) on overlays in memory,
   and it checks and repairs every filesystem at every boot (`fsck.mode=force
   fsck.repair=yes`). IronFlockOS keeps what changes on `/data` and repairs at boot only
   what a preen can.
7. Proof on hardware. `docs/targets/amd64-efi.md` lists QEMU as the only tested board
   and no latency figure.
8. Host settings. The machine raises the socket buffer limits to 50 MiB, presumably for
   camera streams, turns IPv6 off, names its interfaces `eth0` to `eth2`, and serves
   host folders to the machine's internal network from the kernel's NFS server.
   IronFlockOS has no place for settings of this kind.

Known from the machine's owner: every such machine reaches an IronFlock appliance, or
runs the appliance itself, and the device-agent gives an app fixed ports. This record
covers this machine; the builder's other machine types are not decided here.

## Decision

### 1. The line between the image and the apps

The image carries what only the host can: the kernel, its modules and firmware, boot,
updates, time, the network, the firewall and the confinement of containers. Everything
else of a machine is an app. The project grants it privileged access where it needs
devices, the host's network or real-time priority. No package that serves one machine's
function enters `profiles/base`.

### 2. Kernel drivers: this machine takes the stock image

This machine needs no driver from outside the kernel. It takes the stock `base-rt`
image, and Secure Boot stays off, as it is today. The builder's other machine types,
which carry a fieldbus card, CAN interfaces or a vision controller, are not decided
here.

### 3. The screen: a splash from the image, the UI from a kiosk app

- IronFlockOS stays without a display server and without GUI toolkits. Every image
  shows a boot splash by default, IronFlock's logo or a picture the device was given,
  and leaves it on the screen until an app draws.
- The UI is shown by a kiosk app that IronFlock provides: a full-screen browser in a
  container, which shows the web UI of the app it is pointed at and has a key to
  IronFlock Studio. A builder's own GUI can run as an app with the same access to the
  screen: `/dev/dri`, `/dev/input`, `/run/udev` and the first virtual terminal.
- The usual keys stay: the firmware setup, the boot menu, the boot messages, and a login
  prompt on the other virtual terminals.
- The image needs no package for this machine's graphics: the kernel's driver and
  Intel's graphics firmware are in it.
- [kiosk-plan.md](../kiosk-plan.md) has the contract between the image and a screen app,
  and the work packages.

### 4. Updates and apps come from the appliance

- The OS gets no second update path: no bundle from a USB stick, no upload page. A
  machine without a route to the cloud takes its OS bundles, its firmware metadata
  (ADR-0009) and its apps from its appliance, through the `update_url` of its `.flock`.
- A machine without any network runs the appliance itself. Bringing a release or an
  app's image into an appliance without internet access is the appliance's task.

### 5. AppArmor in the Debian images

`apparmor` joins `profiles/base/packages.debian`. Debian's kernels have AppArmor on, so
Docker then confines every container that is not privileged with `docker-default`, as it
does on the Debian and Ubuntu hosts the device-agent runs on. A privileged container
gets no profile. IronFlockOS adds no profiles of its own.

The package also brings the profiles of Debian's packages into force. Debian's profile
for chrony does not allow the folders IronFlockOS gives chrony below `/run/ironflockos`
(the PTP source of ADR-0013 and the NTP servers of `proxy.conf`), so the image adds them
in the profile's local file, and a unit test compares the two. The QEMU tests of PTP and
of the proxy run with AppArmor on, and one checks that Docker and chronyd are confined.
On the Raspberry Pi the kernel is Raspberry Pi's and decides whether AppArmor is on;
with it off the package changes nothing. The Jetson image, Ubuntu on NVIDIA's kernel,
gets the package once it has been tried there.

This machine's functions do not need AppArmor. It is for every device.

### 6. Firewall settings are a feature of the device-agent

- Who may reach a device is set in Studio and applied by the device-agent (section 9).
  The agent already publishes the ports of apps and knows each of them; it gets the
  setting of who may reach them and the host's own ports. The image defines no firewall
  file of its own. Without a setting the inbound side stays open, as today.
- The image brings `nftables`, as it does now. Proposed: the agent keeps the rules it
  made on `/data`, and the image loads them early in the boot, before the agent runs,
  and boots open when they do not load.
- The machine's rules are the reference: only listed ports are reachable, and the rate
  of new connections is limited. Whether the outbound side is filtered too, as the
  machine does today, is decided with the agent's feature.

### 7. The root slot stays read-write; every image repairs its filesystems at boot

- This machine gets no read-only root; its own root is read-write too. Against a power
  cut IronFlockOS has ext4's journal, the fallback to the other slot, its state on
  `/data`, and no mount that can stop the boot.
- Every image gets `fsck.repair=yes` on its kernel command line. A filesystem that a
  preen cannot fix is then repaired at boot instead of being left unmounted. A device
  without `/data` runs no apps (`docs/build.md`, "Disk layout on a device") and nobody
  is there to repair it by hand, so a repair that may drop damaged files is the better
  outcome. The check is not forced at every boot. On the EFI targets the command line
  is in `grub.cfg` on the IRONFLOCKOS partition, which an update does not write: the
  repair comes with a new installation.
- The hardware acceptance cuts the power, while the apps run and while an update writes
  a slot. If a slot is damaged there, the read-only root of the master plan's section 8
  moves forward.

### 8. The machine is converted in place and accepted on IronFlockOS; UEFI only stays

- The survey is done. Nobody is at the machine and its disk may be erased, so there is
  no trial from a USB disk: `ironflock os install`, run on the machine's own system,
  replaces that system with the stock `base-rt` image. The acceptance follows on
  IronFlockOS itself: screen, touch, the three network cards, PTP, the watchdog,
  `cyclictest`. The results go into `docs/targets/amd64-efi.md`.
- IronFlockOS gets no target for legacy BIOS. A machine that boots in BIOS mode is
  switched to UEFI in its firmware setup, or it is not supported.

### 9. Host settings go through the device-agent

- What has to be configurable on a host is a feature of the device-agent: it controls
  the host, and Studio is where a device is configured.
- The image applies at boot what must hold before the agent runs: the network that
  reaches the platform, the proxy, the time, the kernel command line. It reads them from
  files on `/data`, as `ptp.conf`, `rt.conf` and `proxy.conf` are, and the agent is the
  one that writes them.
- The image gets no folder whose files the host loads as modules, sysctl values or udev
  rules. A change made by hand in the root slot, through the agent's host terminal or
  SSH, lasts until the next update, which replaces the slot.
- Nothing is built for this machine's host settings now. Its NFS exports took no
  connection in the six days it had been up, and its camera interface is down. An app
  that needs large socket buffers raises the limit itself, with its privileged access.

## Consequences

- Work for IronFlockOS that is left: the splash and the keys of
  [kiosk-plan.md](../kiosk-plan.md); loading the agent's firewall rules at boot, if
  section 6 is decided that way; the hardware acceptance with its latency figure;
  AppArmor on Jetson.
- Work for the device-agent: the firewall setting (section 6).
- AppArmor reaches every Debian device with its next update. Apps that are not
  privileged run confined from then on, so the apps of the test flock run on such an
  image before it is released. An app that mounts something without being privileged
  needs `apparmor=unconfined`, which is part of the privileged access a project grants.
- The machine's kernel moves from 6.1 to 6.12, and again with Debian 14.
- Installing IronFlockOS replaces the whole disk. The machine keeps its settings on a
  2 GiB partition and its data on a 460 GiB partition, with 17 GiB in use. The builder
  saves both before the installation and restores them into the apps' data. The way back
  is the builder's own installation medium, with a person at the machine; the same holds
  when the new system does not come online.
- The builder restructures the machine's software: apps with their own user space (they
  may stay on Debian 12), a GUI app that owns the screen, fixed ports through the
  device-agent, real-time priorities through `SYS_NICE` and the `rtprio` limit, the
  graphics device for the screen and for inference. The network interfaces get the
  kernel's names (`enp...`) in place of `eth0` to `eth2`.
- The machine takes one minute from power-on to its last service, and about 35 seconds
  to its graphical session. The acceptance measures the same on IronFlockOS, with Docker
  and the apps' start in the path.
- Running the appliance on an IronFlockOS device is handled in IronFlock/ironflock-cli:
  `ironflock appliance` prepares its host outside its install directory, in the root
  slot, which the next OS update replaces. The machine has the memory and the disk for
  the appliance.
- IronFlockOS has no account with a password today, on the screen or over SSH. What a
  person logs in with at the machine's console is open in
  [kiosk-plan.md](../kiosk-plan.md) (O1); the machine's own UI keeps its own users.

## Alternatives considered

- **The device-agent on the builder's own image.** `ironflock agent install` supports
  Debian systems, and the machine would run apps without any change to its drivers and
  screen. The builder keeps maintaining and updating an OS of its own, IronFlock updates
  none of it, and that image has to gain Docker and room for the apps. This stays the
  fallback if the software cannot move into apps.
- **A firewall file of the image's own,** like `ptp.conf`. It would be a second place
  next to the agent, which already decides the ports of apps.
- **An image variant with a display server.** Every builder needs other toolkits and
  versions; this machine alone uses Qt 5, GTK 2 and 3 and Mono. They belong in the app's
  image.
- **Overlays in memory over the folders that change,** as the machine has today. On
  IronFlockOS what changes is on `/data` already, and the apps' data has to outlive a
  restart.
- **Bundles from a USB stick or a local upload page.** Not needed: every machine has an
  appliance.

## Open points

1. To be tried on the machine after the conversion: inference on the Intel graphics from
   a container, on kernel 6.12. The machine's model server uses the graphics device
   today. It is the one function of this machine that no test has covered.
2. Whether the image loads the agent's firewall rules at boot, or the agent applies them
   when it starts (section 6).
