# FlockOS: instructions for coding assistants

FlockOS is the IronFlock device operating system: Debian-based disk images with RAUC A/B
updates, built only in GitHub Actions. Read `docs/master-plan.md` before changing anything;
the architecture decisions are in `docs/adr/`.

- Recipes: `just lint`, `just test`, `just build TARGET VARIANT`. CI runs exactly these.
- Releases: bump `VERSION` through `just release-patch|minor|major`; never tag by hand.
- Host setup logic belongs to `IronFlock/device-init` (`ironflock-init`), not to this repo.
- No secrets, keys or passwords in the tree; signing uses Cloud KMS from the release workflow.
- The pre-rebuild Buildroot and Cubic trees are at the git tag `legacy/reswarmos-0.5.7`.
