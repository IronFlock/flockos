# ADR-0014: The proxy is a device setting that comes with the boot medium

Status: accepted, 2026-11-10.

## Context

Many sites reach the internet only through an HTTP proxy. The device-agent works behind
one: it takes `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` from its environment for its
platform connection, its downloads and its tunnels, and passes them to the apps it starts.
On other Linux systems `ironflock-init agent --http-proxy` writes systemd drop-ins for the
agent and Docker.

IronFlockOS had no proxy setting. Its enrollment (`ironflock-init enroll`) and the `.flock`
carry none, and a drop-in written by hand lives on the root slot, which the next A/B
update replaces. A device that needs a proxy never reaches the platform, so the platform
cannot set it either: the device has to know the proxy from its first boot.

NTP does not pass an HTTP proxy. A network that forces web traffic through a proxy often
blocks NTP to the internet too, and without the right time TLS through the proxy fails.

## Decision

- `/etc/ironflockos/proxy.conf`, on `/data`, holds `http_proxy`, `https_proxy`, `no_proxy` and
  `ntp`. `ironflockos-proxy` writes `/run/ironflockos/proxy.env` from it at boot, before
  containerd, Docker, the agent and chrony, and on every change of the file, restarting
  those that run. Drop-ins in the image give the file to the three services; `ntp` adds
  chrony sources.
- `NO_PROXY` holds the loopback names and, from the device's `.flock`, the hosts the
  agent's own installer keeps off a proxy: the appliance's domain and the LAN registries.
- A `proxy.conf` on the IRONFLOCKOS partition replaces the device's at the next boot and leaves
  the partition, as a `.flock` does. FlockFlasher writes it; the installer stick passes it
  on to the disk it installs.

## Consequences

- A device behind a proxy reaches the platform from its first boot, and keeps the proxy
  through updates.
- A device whose proxy changed while it was offline gets the new one from its boot medium.
- Apps get the proxy through the agent, as on other Linux systems.
- The platform cannot set or change the proxy yet. The `.flock` could carry it later, for
  every OS; the device's file would stay the place it ends up on IronFlockOS.
