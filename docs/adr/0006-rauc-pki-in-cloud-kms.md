# ADR-0006: RAUC bundle signing with a CA whose keys live in Cloud KMS

Status: accepted, 2026-11-04.

## Context

Today every build directory generates its own self-signed RAUC certificate with a
365-day lifetime; the certificate is baked into the image as the keyring, so only
bundles signed with that exact key install, and both certificates in use are expired.
One private key was committed to a private repo. Raspberry Pis have no RTC, so
certificate validity checks against the system clock fail at boot. The other IronFlock
repos already sign releases with Cloud KMS through Workload Identity Federation.

## Decision

- An IronFlockOS **root CA** (RSA 4096 or EC P-384, 20-year validity) is created once; its
  key lives in Cloud KMS (`ironflock-release/ironflockos-rauc-ca`) and is used only to
  issue signer certificates.
- A **bundle signer** certificate (3-year validity, rotated before expiry) is issued
  from the CA; its key is `ironflock-release/ironflockos-rauc-signer` in Cloud KMS and
  never leaves it.
- The device keyring `/etc/rauc/keyring.pem` contains the CA certificate, so signer
  rotation requires no device update. `system.conf` sets
  `use-bundle-signing-time=true` and `bundle-formats=verity`.
- CI signs with `rauc bundle --cert signer.pem --key 'pkcs11:…'` through Google's
  PKCS#11 library (`RAUC_PKCS11_MODULE`, `KMS_PKCS11_CONFIG`), authenticated by WIF as
  `ironflockos-release@record-1283` with `roles/cloudkms.signer`. Pull-request dry runs use
  an ephemeral key and embed its certificate, so PR images and release bundles are
  mutually incompatible.
- The 2021 and 2025 certificates and keys are retired; `gs://reswarmos-certs` is
  emptied; the key in the old ironflockos repo is documented as compromised.
- The signed release catalog (`dl/ironflockos/manifest.json`) reuses the agent's existing
  detached-signature scheme and key infrastructure.

## Consequences

- No key material on runners or in repositories; signing is auditable in Cloud KMS logs.
- Legacy ReswarmOS devices cannot verify IronFlockOS bundles (different keyring); they are
  reflashed, which the different partition layout requires anyway.
- Certificate expiry becomes an operational calendar item (signer rotation every 3
  years) rather than a yearly surprise.

## Implementation note (2026-11-04, WP-0.5)

The keys live in two dedicated key rings, `ironflockos-rauc-ca/root` and
`ironflockos-rauc/bundle-signer`, instead of `ironflock-release`: Google's PKCS#11
library needs list rights on the whole ring it signs from, and the release
identity must not see other products' release keys or the CA. Both keys are
HSM-protected RSA 4096 with PKCS#1 SHA-256 (RAUC signs SHA-256 digests; an
EC P-384 KMS key would accept only SHA-384). Details in `docs/signing.md`.
