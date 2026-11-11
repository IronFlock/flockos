# ADR-0012: The OS is named IronFlockOS, and machine identifiers keep flockos

Status: accepted, 2026-11-09. The identifiers that keep `flockos` below are renamed after
all: [ADR-0017](0017-every-name-is-ironflockos.md), 2026-11-11.

## Context

The OS was named FlockOS. Other companies use that name for their own products, and the
OS is part of IronFlock, so its name should say so.

Devices, tools and published releases already depend on `flockos` in identifiers. Some
of them cannot change without a migration of devices in the field.

## Decision

The name of the product is IronFlockOS. It is used for the repository
(`IronFlock/ironflockos`), `NAME` and `PRETTY_NAME` in `os-release`, the boot menus, the
console messages, the unit descriptions, `osname` in the catalog, and the documentation.

Identifiers that software matches, or that are already in the field, keep `flockos`:

- `ID=flockos` in `os-release`: the device-agent recognises an updatable image by it.
- The RAUC `compatible` and the image IDs, `flockos-<target>-<variant>[-rt]`: a device
  installs only bundles whose `compatible` is its own.
- The certificate subjects of the RAUC PKI (`CN=FlockOS root CA`): the root CA is in the
  keyring of every device.
- The `FLOCKOS` partition label: FlockFlasher and the enrollment find the partition by it.
- The download paths (`dl/flockos/`), artifact names, `/usr/lib/flockos`, `/data/flockos`,
  systemd unit names, and the service accounts and KMS keys.

## Consequences

- An update from an earlier release needs no migration: only names shown to people change.
- Provenance is bound to the repository name at build time. Releases up to 0.12.0 are
  checked with `--repo IronFlock/flockos`, later ones with `--repo IronFlock/ironflockos`.
- Older ADRs and plans use the new name in their text. Where they name the repository at
  an earlier time, `IronFlock/flockos` stays, because that is what happened. Published
  release notes are not changed.
- Changing `compatible` or the CA's subject would need its own decision and a migration
  bundle.
