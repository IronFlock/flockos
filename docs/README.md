# FlockOS documentation

| Document | Purpose |
|----------|---------|
| [master-plan.md](master-plan.md) | The plan of record: goals, target architecture, phased roadmap, cross-repo changes, risks |
| [implementation-plan.md](implementation-plan.md) | The work packages: status board, milestones, dependencies, per-WP scope, deliverables and acceptance; one GitHub issue per WP |
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

Planned additions as the phases land: `signing.md` (the PKCS#11 recipe), `targets/<target>.md`
(per-target boot, layout and hardware notes), `testing.md` (QEMU and hardware checklists),
`migration.md` (reflashing ReswarmOS devices).
