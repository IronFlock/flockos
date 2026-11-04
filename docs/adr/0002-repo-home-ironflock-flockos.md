# ADR-0002: The repo moves to IronFlock/flockos and stays public

Status: accepted, 2026-11-04.

## Context

The repo is `RecordEvolution/ReswarmOS` (public). The IronFlock CI harness
(`IronFlock/workflows`), the release GitHub App, the Workload Identity Federation
service accounts and the rulesets are set up for the IronFlock organisation. A private
`IronFlock/flockos` repo exists; it is an abandoned Buildroot fork whose history contains
a RAUC private key.

## Decision

Transfer `RecordEvolution/ReswarmOS` into the IronFlock organisation as `flockos`,
public, default branch `main`. Archive the old private `IronFlock/flockos` after moving
its useful 64-bit Raspberry Pi notes into `docs/`, with an archive README that records
the committed key and its retirement.

## Consequences

- Public: GitHub-hosted arm64 runners (`ubuntu-24.04-arm`) are free, the Security tab
  is available, and the attestation and SBOM tooling of the harness works unchanged.
- Public also means no key material, no internal hostnames beyond the already public
  `instance-registry.ironflock.com`, and the standard rulesets from day one.
- Links in the old catalog and docs that point at `RecordEvolution/ReswarmOS` keep
  working through GitHub's transfer redirects.
- Release signing uses WIF and KMS only; pull-request builds use ephemeral keys.
