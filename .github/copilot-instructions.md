# FlockOS: instructions for coding assistants

FlockOS is the IronFlock device operating system: Debian-based disk images with RAUC A/B
updates, built only in GitHub Actions. Read `docs/master-plan.md` before changing anything;
the architecture decisions are in `docs/adr/`.

- Recipes: `just lint`, `just test`, `just build TARGET VARIANT`. CI runs exactly these.
- Releases: bump `VERSION` through `just release-patch|minor|major`; never tag by hand.
- Host setup logic belongs to `IronFlock/device-init` (`ironflock-init`), not to this repo.
- No secrets, keys or passwords in the tree; signing uses Cloud KMS from the release workflow.
- Buildroot and Cubic are retired (ADR-0001); do not bring them back.
