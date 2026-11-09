# ADR-0009: Phase 2 decisions: hostname, release channels, first firmware lane

Status: accepted, 2026-11-05 (WP-2.0). Settles the master plan's open questions 1, 2
and 4; question 5 was settled by WP-4b.1.

## Context

Phase 2 connects IronFlockOS to the IronFlock platform: enrollment from the `.flock`
(WP-2.1 to WP-2.3), OS updates through the device-agent (WP-2.4, WP-2.8), firmware
(WP-2.5, WP-2.9) and the signed catalog that the release pipeline publishes and
FlockFlasher reads (WP-2.6, WP-2.7). The master plan left four questions for the start
of Phase 2 (section 7). Three teams read the catalog, so its shape is agreed here too.

## Decisions

### 1. Hostname from the `.flock` by default

On IronFlockOS, `flockos-enroll` runs `ironflock-init enroll --hostname-from-flock`: every
device is named after its device name in the platform, as ReswarmOS devices were.
`ironflock-init` makes the name a valid hostname (an RFC 1123 label) and keeps the
current hostname when nothing valid is left. A device keeps its hostname with
`hostname-from-flock=no` in `/etc/flockos/enroll.conf`, which links to
`/data/flockos/enroll.conf` and so outlives updates. device-init on other Linux systems
keeps leaving the hostname alone: there the machine was named by its owner.

### 2. Two release channels: production and test

`dl/flockos/manifest.json` names a version for `production` and, optionally, for `test`.
Devices marked as test devices in the platform follow `test`; all others `production`.
A release goes to `test` first; promoting it moves `production` to its version, without
a rebuild. This mirrors the device-agent's own manifest (`channels.production`,
`channels.test`), so the platform's notion of a test device covers both.

### 3. First firmware lane: boot firmware with OS releases, fwupd read-only

Boot firmware (the Raspberry Pi EEPROM, Jetson QSPI capsules) ships inside the OS
release (lanes 1 and 2 of ADR-0007), so it is tested with the release it belongs to and
needs no platform action of its own. Component firmware through fwupd (lane 3) starts
read-only: the device-agent reports fwupd's devices and their firmware versions, and the
platform shows them (WP-2.5, WP-2.9). Updates through fwupd and LVFS follow once the
inventory has shown what the fleet carries.

*Amended 2026-11-08:* the updates were brought forward, per device and on an operator's
request. The agent reports what fwupd offers and its history with the inventory, fetches
LVFS metadata itself (daily, as the image masks `fwupd-refresh.timer`), and installs one
offered version on `install_firmware_update`, which needs `MAINTAIN`, shares the OS
update's lock and takes only a device id and a version: the address and checksum come
from fwupd's signed metadata. The restart stays the operator's. Maintenance windows and
staged roll-out across a fleet are not built yet (#200), and no IronFlock-signed remote
exists: LVFS only.

The agent reads LVFS through its update base first (`<update base>/lvfs/`), which is the
cloud's download proxy or an appliance's mirror, and LVFS itself if that fails, so that
edge devices without internet access can update through their appliance. The path needs
no trust: fwupd checks the signature of the metadata, and the agent the checksum that
metadata names for the firmware. No image change comes with it.

### 4. The catalog: `docs/manifest.schema.json`

One document serves both readers ([schema](../manifest.schema.json),
[example](../manifest.example.json)):

- `channels`: the version per channel.
- `releases`: per version `build_id`, `buildtime`, `min_agent` (the oldest device-agent
  that may install it) and `images` by `IMAGE_ID`, each with its `image` (`.img.gz`) and
  `bundle` (`.raucb`, with its RAUC `compatible`; none for the installer), every file with
  URL, SHA-256 and size. The device-agent looks up its own `IMAGE_ID` under the version
  of its channel.
- `boards`: FlockFlasher's `SupportedBoard` and `ImageInfo` shape for the production
  release, plus `image_id`, `variant` and `kernel` for the variant choice of WP-2.7.
  `osvariant` is always `image`: every IronFlockOS artefact is a raw image (ADR-0004).

The document is published in the device-agent's envelope (`{"payload": "<base64>",
"signature": "<Ed25519 .sig>"}`, at most 64 KiB), signed over
`flockos-manifest:v1`, `flockos/manifest.json` and the payload's SHA-256, with an
Ed25519 key in Cloud KMS that only IronFlockOS release runs may use (WP-2.6). The
device-agent and FlockFlasher compile its public key in. `issued_at` lets a reader
refuse a document older than the last one it accepted.

### 5. Real-time tuning (open question 5, settled by WP-4b.1)

The platform sets it per device: it writes `/data/flockos/rt.conf`, which
`flockos-rt-tuning` applies. Without the file an `-rt` image limits C-states and
isolates nothing.

## Consequences

- WP-2.4 and WP-2.7 read the catalog by this schema; a change that breaks a reader
  raises `schema`.
- WP-2.5 provided the fwupd inventory RPCs first; the update RPCs followed (see the
  amendment in section 3). WP-2.9 shows the inventory and offers the installs.
- WP-2.6 creates the manifest signing key and publishes the document with the release.
- Every enrolled IronFlockOS device has the hostname of its `.flock`; the QEMU test checks
  it.

Open: who owns the GPU and Orin hardware for the acceptance tests of Phases 4 and 6
(question 3).
