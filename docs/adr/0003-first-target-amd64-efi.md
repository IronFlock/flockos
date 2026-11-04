# ADR-0003: amd64 UEFI PCs are the first target

Status: accepted, 2026-11-04.

## Context

Targets: generic amd64/arm64 edge PCs, Raspberry Pi, NVIDIA GPU hosts, Jetson Orin.
Only one can be first. Raspberry Pi has the most existing users but needs real-hardware
boot testing and a new A/B design. Jetson Orin has the highest effort. amd64 UEFI can
be built and boot-tested entirely inside GitHub Actions with QEMU and OVMF, and the
NVIDIA x86 variant is the same image plus a driver profile.

## Decision

`amd64-efi` is delivered first, including the full RAUC A/B loop and the QEMU test
harness. `nvidia` and `installer` variants follow on the same target. Raspberry Pi
arm64, Jetson Orin and generic arm64 EFI come after the release pipeline exists.

## Consequences

- The build framework, the `/data` state design, the enroll flow, the update client
  and the release pipeline are all proven on a target that CI can boot.
- Raspberry Pi users wait for Phase 5; the legacy ReswarmOS images stay available but
  frozen meanwhile.
