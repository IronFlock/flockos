# ADR-0013: chrony keeps the time, with PTP per device as client or master

Status: accepted, 2026-11-10.

## Context

Images used systemd-timesyncd, an NTP client only. Machines in production networks often
share their time over PTP (IEEE 1588), with time stamps in the network card's hardware,
accurate to well under a microsecond. Vision systems and controllers rely on that shared
timeline. A device either takes the time from a master on its machine network, or is
itself the master for devices such as cameras. The first such device is a panel PC that
runs `ptp4l` and `phc2sys` on its machine network today.

PTP cannot replace NTP. A client needs a master on the local network, which most devices do
not have: offices, Compute Engine VMs, Raspberry Pis, most factory networks. A device
without time loses its TLS connections to the platform and cannot check its updates. PTP
also needs settings per site: the interface, the role, the domain, the transport and the
delay mechanism.

If an app ran `phc2sys` to set the clock, it would fight timesyncd for it, and it would
need `SYS_TIME`, host networking and `/dev/ptp*` only to keep the OS's clock right.

## Decision

- chrony replaces systemd-timesyncd in every image. It keeps the distribution's NTP pools,
  uses the NTP servers DHCP hands out, and starts with `-s`, which restores the time of its
  last run on boards without a real-time clock, as timesyncd's clock file did.
- `linuxptp` is in every image, off until the device's `/etc/ironflockos/ptp.conf`
  (on `/data`) names an interface. The file also sets the role, client by default.
- **client:** `ptp4l` keeps the interface's hardware clock on the master's time and never
  becomes a master. `phc2sys` hands that time to chrony through a socket, as linuxptp's
  `timemaster` does. chrony uses PTP while it is there and falls back to NTP when the
  samples stop.
- **server:** `ptp4l` is the master on the interface and never takes time from it, with a
  `priority1` of 64 by default, so it wins against clocks at the default 128. `phc2sys`
  keeps the hardware clock on the system clock, which chrony keeps on NTP; it starts after
  chrony's first synchronisation, or after two minutes without one.

## Consequences

- Devices without `ptp.conf` work as before, with chrony instead of timesyncd.
- A client keeps PTP time without internet access, and NTP time when the master goes away.
- A server's clients share the device's timeline. Its absolute time is as good as NTP; a
  correction of the system clock reaches the clients.
- Apps read the clock. None needs `SYS_TIME` or `/dev/ptp*` to keep it right.
- A device that is a client of a plant master on one interface and the master for its
  cameras on another (a boundary clock) is not covered. `ptp4l` can do that across two
  network cards; it needs its own setup.
- The platform has no setting for `ptp.conf` yet; it is written on the device.
