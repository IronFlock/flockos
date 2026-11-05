# FlockOS documentation

| Document | Purpose |
|----------|---------|
| [master-plan.md](master-plan.md) | The plan of record: goals, target architecture, phased roadmap, cross-repo changes, risks |
| [implementation-plan.md](implementation-plan.md) | The work packages: status board, milestones, dependencies, per-WP scope, deliverables and acceptance; one GitHub issue per WP |
| [build.md](build.md) | How an image is built: stages, artefacts, disk layout on a device, boot and A/B, local builds |
| [testing.md](testing.md) | Unit tests, the QEMU image test, the hardware checklist |
| [signing.md](signing.md) | The RAUC PKI in Cloud KMS: creating it, how releases sign, renewal |
| [release.md](release.md) | How a release runs: build, sign, test, stage, promote, the signed catalog, the tag; the one-time setup |
| [manifest.schema.json](manifest.schema.json) | The release catalog `dl/flockos/manifest.json` the device-agent and FlockFlasher read (ADR-0009), with an [example](manifest.example.json) |
| [targets/amd64-efi.md](targets/amd64-efi.md), [arm64-efi.md](targets/arm64-efi.md), [rpi-arm64.md](targets/rpi-arm64.md) | Target notes and tested hardware |
| [current-state-audit.md](current-state-audit.md) | Evidence: what the `buildroot/` and `cubic/` trees, the published catalog, and the sibling repos do today |
| [adr/](adr/) | Architecture decision records |

## Decisions

| ADR | Decision | Status |
|-----|----------|--------|
| [0001](adr/0001-debian-based-image-for-all-targets.md) | One Debian-based image pipeline for all targets; Buildroot and Cubic retired | accepted |
| [0002](adr/0002-repo-home-ironflock-flockos.md) | Repo moves to `IronFlock/flockos`, stays public | accepted |
| [0003](adr/0003-first-target-amd64-efi.md) | amd64 UEFI PCs first | accepted |
| [0004](adr/0004-raw-image-plus-installer-usb.md) | Raw disk images everywhere, FlockOS installer USB for PCs | accepted |
| [0005](adr/0005-builder-mmdebstrap-genimage.md) | mmdebstrap + genimage behind a just/shell framework | proposed |
| [0006](adr/0006-rauc-pki-in-cloud-kms.md) | RAUC signing with a CA in Cloud KMS via PKCS#11 | accepted |
| [0007](adr/0007-update-mechanism-rauc-and-firmware-lanes.md) | RAUC stays the OS updater; firmware in three lanes (bundle, RAUC hooks, fwupd); alternatives compared | accepted |
| [0008](adr/0008-jetson-orin-bsp-jetpack-7.md) | Jetson Orin on Jetson Linux r39.2.1 (JetPack 7.2.1), Ubuntu 24.04; rootfs from NVIDIA's apt repositories, BSP tarball for flashing and capsules | accepted (licence review before the first Jetson release) |
| [0009](adr/0009-phase-2-decisions-hostname-channels-firmware.md) | Phase 2: hostname from the `.flock`, release channels production and test, boot firmware with OS releases and fwupd read-only first, the catalog schema | accepted |

Planned additions as the phases land: `targets/<target>.md` for the other targets,
`migration.md` (reflashing ReswarmOS devices).
