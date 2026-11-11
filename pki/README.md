# IronFlockOS public keys

Public certificates of the IronFlockOS RAUC PKI (ADR-0006, [docs/signing.md](../docs/signing.md))
and the public key of the release catalog (ADR-0009, [docs/release.md](../docs/release.md)).
The private keys never leave Cloud KMS.

| File | What | Valid |
|------|------|-------|
| `ironflockos-root-ca.pem` | root CA: the keyring of every release image (`/etc/rauc/keyring.pem`) | 20 years |
| `ironflockos-bundle-signer-<year>.pem` | bundle signer used by release runs | 3 years, renewed before expiry |
| `ironflockos-catalog.pub` | verifies the signed catalog `dl/ironflockos/manifest.json` | while its key version is enabled |

Created by `tools/rauc-pki/ceremony.sh` and `tools/release-setup.sh` on 2026-11-11, with
the names of ADR-0017. Both certificate keys are RSA 4096 in Cloud KMS HSMs (project
`record-1283`, `europe-west1`, key rings `ironflockos-rauc-ca` and `ironflockos-rauc`); the
CA key version is disabled between certificate issues.

| File | Subject | Valid until | SHA-256 fingerprint |
|------|---------|-------------|---------------------|
| `ironflockos-root-ca.pem` | `O=IronFlock, CN=IronFlockOS root CA` | 2046-11-11 | `3E:D9:A2:E6:E2:25:D6:8B:BD:98:D4:38:32:3A:73:AF:E5:C6:AA:9F:75:A1:A3:B5:82:4E:FC:FD:DA:03:91:91` |
| `ironflockos-bundle-signer-2026.pem` | `O=IronFlock, CN=IronFlockOS bundle signer 2026` | 2029-11-11 | `AF:1E:D0:A0:5D:6B:4C:0A:D0:CB:35:DD:41:78:35:67:91:6D:65:04:F4:DB:C2:02:4E:93:AF:8A:AC:25:D7:22` |

Check a copy with `openssl x509 -in <file> -noout -fingerprint -sha256` and the chain
with `openssl verify -CAfile ironflockos-root-ca.pem ironflockos-bundle-signer-2026.pem`.
Release builds trust the root CA, and `release.yml` signs their bundles with the bundle
signer (WP-1.6); every other build signs with throwaway keys.

## The catalog key

`ironflockos-catalog.pub` verifies the signed catalog `dl/ironflockos/manifest.json`
(ADR-0009). The device-agent, the `ironflock` CLI, FlockFlasher, the backend and the
appliance's mirror check the catalog with it (`IRONFLOCKOS_CATALOG_PUBLIC_KEYS` and the
like), and so does `release.yml` before it moves a release (`tools/catalog verify`).

| | |
|---|---|
| Key | `ironflock-release/ironflockos-catalog`, version 1: Ed25519 (`EC_SIGN_ED25519`), software protection, as the agent's `agent-update` key |
| Signer | only `ironflockos-release`, the release identity (`roles/cloudkms.signerVerifier` on this key) |
| Raw public key (base64, the agent's form) | `+OG0Ylau0tkCKEDT+WGc9RYHOa9VCSxiOGBBTp7IEQc=` (key id `036ef3bd`) |
| SHA-256 of the DER public key | `b414dc4acdb8dfb6ff8a175f077c7675e32459d52ae5a7c59d87f31b9f5823c8` |

Created by `tools/release-setup.sh` on 2026-11-11, with the publisher identity
`ironflockos-publisher`. Check a copy against Cloud KMS with
`gcloud kms keys versions get-public-key 1 --key ironflockos-catalog --keyring ironflock-release --location europe-west1 --project record-1283`,
and get the agent's form with
`openssl pkey -pubin -in ironflockos-catalog.pub -outform DER | tail -c 32 | base64`.

## Earlier keys

The releases up to 0.15.0 were signed with the keys of the old names, from 2026-11-05:
the root CA `CN=FlockOS root CA` (key ring `flockos-rauc-ca`), the bundle signer
`CN=FlockOS bundle signer 2026` (key ring `flockos-rauc`) and the catalog key
`ironflock-release/flockos-catalog` (key id `f5e1308e`). Their files are in the history of
this repository; `tools/retire-old-names.sh` disables the keys once the new download tree
and its clients are live.
