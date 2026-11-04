<p align="center">
  <a href="https://www.ironflock.com">
    <img alt="IronFlock" src="https://res.cloudinary.com/dotw7ar1m/image/upload/v1708079370/vli89gsgy2siqcrmvzfm.png" width="400" />
  </a>
</p>

# FlockOS

FlockOS is the operating system IronFlock ships for its edge devices: a Debian-based,
image-based appliance OS whose job is to run the IronFlock device-agent and Docker, with
A/B updates through RAUC, built and signed only in GitHub Actions.

**Status (November 2026): rebuild in progress.** This repository was `ReswarmOS`
(Buildroot images for 32-bit Raspberry Pi and a Cubic-made x86 installer). Those trees
were removed; they remain at the git tag `legacy/reswarmos-0.5.7`. The plan of record,
the audit of the previous state and the architecture decisions live in [docs/](docs/README.md),
starting with [docs/master-plan.md](docs/master-plan.md).

## Targets and variants

| Target | Hardware | A/B mechanism |
| ------ | -------- | ------------- |
| `amd64-efi` | UEFI x86 edge PCs and IPCs | GRUB + RAUC |
| `arm64-efi` | UEFI arm64 boards and VMs | GRUB + RAUC |
| `rpi-arm64` | Raspberry Pi 4, 5, CM4, CM5 (Pi 3 and Zero 2 W without A/B) | Pi firmware tryboot + RAUC |
| `jetson-orin` | NVIDIA Jetson Orin (Nano devkit SD image; NX/AGX flash package) | NVIDIA UEFI `nvbootctrl` + RAUC |

Variants: `base`, `nvidia` (GPU in containers on x86), `installer` (a USB stick that
installs FlockOS on an internal disk). Every target can be built with a PREEMPT_RT kernel
(`-rt`). Images are flashed with [FlockFlasher](https://github.com/IronFlock/flasher);
devices are set up by [device-init](https://github.com/IronFlock/device-init), which the
image ships and calls rather than re-implementing.

## Working in this repository

```sh
just lint                     static checks as CI runs them
just test                     unit tests of the build scripts
just build amd64-efi base     build one image (Phase 1)
```

Pull requests into `main` need the `ci-ok` and `security / report` checks. A release is a
version bump: `just release-patch` (or `-minor`, `-major`) opens the pull request titled
`release flockos v<version>`; its merge runs `.github/workflows/release.yml`, which builds
every image, signs the RAUC bundles in Cloud KMS, publishes them, and sets the tag last.
Nothing is built, signed or published from a laptop.

## Documentation

- [docs/master-plan.md](docs/master-plan.md): goals, architecture, roadmap, cross-repo changes
- [docs/current-state-audit.md](docs/current-state-audit.md): what the previous trees did and why they were replaced
- [docs/adr/](docs/adr/): architecture decision records

## License

Apache License 2.0, see [license.md](license.md).
