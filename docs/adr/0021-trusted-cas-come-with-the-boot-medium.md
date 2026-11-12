# ADR-0021: Trusted CAs are a device setting that comes with the boot medium

Status: accepted, 2026-11-12. First in IronFlockOS 0.17.0.

## Context

A device that is managed through an IronFlock appliance reaches it over TLS: the
device-agent opens `wss://ws.<domain>`, Docker and containerd pull from
`registry.<domain>`, and OS updates come from the appliance's mirror over https. At
many sites the appliance's TLS certificate comes from a corporate CA: the chain is the
leaf, a corporate sub CA and a corporate root CA. The agent and Docker are Go programs
and check the chain against the system's trust store,
`/etc/ssl/certs/ca-certificates.crt`, as curl and OpenSSL do. That store holds the
public CAs of Debian's `ca-certificates` and nothing else, so such a device cannot
connect.

IronFlockOS had no way to trust an extra CA. A certificate added by hand to
`/usr/local/share/ca-certificates` lives on the root slot, which the next A/B update
replaces. The platform cannot hand the CA to the device either: the device needs it to
reach the platform in the first place. This is the situation of the proxy
([ADR-0014](0014-proxy-per-device-from-the-ironflockos-partition.md)).

## Decision

- The device's set of trusted CAs is `/etc/ironflockos/ca.crt`, which the image links
  to `/data/ironflockos/ca.crt`, so it outlives updates: one or more PEM certificates
  (`-----BEGIN CERTIFICATE-----` … `-----END CERTIFICATE-----`). Text outside the blocks
  is a comment.
- A `ca.crt` on the IRONFLOCKOS partition, next to the `.flock` and `proxy.conf`,
  replaces the device's set at the next boot and leaves the partition. Its certificates
  become the set; a file without a certificate block clears it. Every block must be a
  certificate OpenSSL can read, else the file is refused as a whole: it stays on the
  partition, the device keeps its set, the reason goes to the journal and the unit
  fails, as with `proxy.conf`. A file that is not text (a DER certificate) is refused the
  same way. `ironflock os install` writes the file (the machine's own extra CAs and the
  files of `--ca-cert`), and so does `ironflock os flash --ca-cert`. The installer stick
  passes it on to the disk it installs.
- During a factory reset the partition's `ca.crt` follows
  `/run/ironflockos/factory-reset-hold` as `proxy.conf` does (ADR-0015): it waits, or is
  taken and left there; without `/data` it is taken and left there. After a give-up
  with the old data it is removed with the request's `.flock` and `proxy.conf`.
  `keep-network=yes` keeps `/data/ironflockos/ca.crt` with the other network settings.
- `ironflockos-ca` puts the set into the system's trust store at every boot, after
  `/data` is mounted and before containerd, Docker, the agent, fwupd and RAUC start: one
  file per certificate in `/usr/local/share/ca-certificates/ironflockos`, named by its
  SHA-256 fingerprint, then `update-ca-certificates --fresh`, only when the files
  changed. A mark in that folder makes a run that failed or lost its power run again.
  A new slot has none of the files, so its first boot puts them in. The journal names
  each CA the device trusts, with its subject and fingerprint.
- `ironflockos-ca.path` applies a change of the device's file at once and restarts
  containerd, Docker and the agent when the store changed: Go reads the store once,
  when a program starts.

## Consequences

- A device behind an appliance with a corporate certificate reaches it from its first
  boot, and keeps the CAs through updates, rollbacks and a factory reset that keeps the
  network.
- A device whose appliance changed its CA while the device was offline gets the new set
  from its boot medium.
- The CAs are trusted by everything on the host that uses the system's store, not by the
  appliance's names alone. That is how the machine the CLI runs on trusts them, and the
  CLI copies what that machine trusts; a set should hold the site's own CAs only.
- Containers keep their own trust stores: an app that talks to the appliance over TLS
  brings the CA itself.
- The platform cannot set the CAs yet. Later the appliance can stamp its own CA chain
  into the `.flock` it hands out, for every OS; on IronFlockOS the chain would end up in
  the same device file.
- A read-only root slot (dm-verity, in the master plan) has no writable
  `/usr/local/share/ca-certificates` or `/etc/ssl/certs`. The store would then be built
  elsewhere, under `/run` or `/data`, and the programs pointed at it.
