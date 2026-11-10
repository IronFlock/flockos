# ADR-0013: chrony keeps the time, with PTP as a source per device

Status: accepted, 2026-11-10.

## Context

Images used systemd-timesyncd, an NTP client only. Machines in production networks often
take their time from PTP (IEEE 1588): a grandmaster on the machine network, with time
stamps in the network card's hardware, accurate to well under a microsecond. Vision
systems and controllers rely on that shared timeline. The first such device is a panel
PC that runs `ptp4l` and `phc2sys` on its machine network today.

PTP cannot replace NTP. It needs a master on the local network, which most devices do not
have: offices, Compute Engine VMs, Raspberry Pis, most factory networks. A device without
time loses its TLS connections to the platform and cannot check its updates. PTP also needs
settings per site: the interface, the domain, the transport and the delay mechanism.

If an app ran `phc2sys` to set the clock, it would fight timesyncd for it, and it would
need `SYS_TIME`, host networking and `/dev/ptp*` only to keep the OS's clock right.

## Decision

- chrony replaces systemd-timesyncd in every image. It keeps the distribution's NTP pools,
  uses the NTP servers DHCP hands out, and starts with `-s`, which restores the time of its
  last run on boards without a real-time clock, as timesyncd's clock file did.
- `linuxptp` is in every image, off until the device's `/etc/flockos/ptp.conf`
  (on `/data`) names an interface. Then `ptp4l` keeps that interface's hardware clock on
  the master's time as a client only, and `phc2sys` hands that time to chrony through a
  socket, as linuxptp's `timemaster` does. chrony uses PTP while it is there and falls back
  to NTP when the samples stop.
- The device never serves PTP to others.

## Consequences

- Devices without `ptp.conf` work as before, with chrony instead of timesyncd.
- A device on a PTP network keeps PTP time without internet access, and NTP time when the
  master goes away.
- Apps read the clock. None needs `SYS_TIME` or `/dev/ptp*` to keep it right.
- A device that has to be the PTP master for other machines, for example for cameras, is
  not covered. That needs its own decision: the hardware clock would follow the system
  clock instead.
- The platform has no setting for `ptp.conf` yet; it is written on the device.
