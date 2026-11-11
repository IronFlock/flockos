# ADR-0017: Every name of the OS is ironflockos

Status: accepted, 2026-11-11. Renames the identifiers that
[ADR-0012](0012-the-os-is-named-ironflockos.md) kept as `flockos`.

## Context

ADR-0012 renamed the product to IronFlockOS but kept `flockos` in identifiers, so that
devices in the field would need no migration. No device runs IronFlockOS in production
yet. A rename costs no migration now; later it would.

## Decision

Every name that still says flockos says `ironflockos`, `IronFlockOS` or `IRONFLOCKOS`.
FlockFlasher and FlockAgent keep their names.

- `ID=ironflockos` in `os-release`; the image ids and the RAUC `compatible`,
  `ironflockos-<target>-<variant>[-rt]`.
- The partition `IRONFLOCKOS` (GPT name and FAT label), still mounted at `/boot/efi`.
- The downloads: `dl/ironflockos/` and `gs://ironflock-downloads/ironflockos/`, the
  catalog `dl/ironflockos/manifest.json` with the signing context
  `ironflockos-manifest:v1`.
- On the device: `/usr/lib/ironflockos`, `/etc/ironflockos`, `/data/ironflockos`,
  `/var/cache/ironflockos` and the other folders, the units `ironflockos-*`, the GRUB
  variables `IRONFLOCKOS_CMDLINE` and `IRONFLOCKOS_RT_CMDLINE`.
- The Compute Engine images `ironflockos-<image>-v<x-y-z>` in the families
  `ironflockos-<image>`, the instance metadata key `ironflockos-flock`, the guest
  attributes `ironflockos/`.
- The build and CI variables `IRONFLOCKOS_*`.
- What Cloud KMS and IAM cannot rename is made anew: the key rings `ironflockos-rauc-ca`
  and `ironflockos-rauc` with the certificates `CN=IronFlockOS root CA` and
  `CN=IronFlockOS bundle signer <year>` (`tools/rauc-pki/ceremony.sh`), the catalog key
  `ironflock-release/ironflockos-catalog`, the service accounts `ironflockos-release`
  and `ironflockos-publisher` and the role `ironflockosVmImagePublisher`
  (`tools/release-setup.sh`).

## Consequences

- A device on 0.15.0 or earlier gets no update to a later release: its `compatible`,
  keyring and partition name are the old ones. It is flashed again.
- The next release starts a new download tree and a new catalog, signed with the new
  key. The device-agent, the `ironflock` CLI, FlockFlasher, the backend and the
  appliance's mirror read only that tree, in their releases after it.
- The order: the ceremony and `tools/release-setup.sh` (a project owner), a release
  into the new tree, then the releases of those clients against it. Until then
  releases up to 0.15.0 stay in `dl/flockos/`. Once the new tree and the clients are
  live, `tools/retire-old-names.sh` removes that tree and the old Compute Engine
  images, and disables the old keys, service accounts and role.
- Published release notes, the provenance of earlier releases (bound to the
  repository name at build time) and ADR-0002 keep the old names, because that is what
  happened.
