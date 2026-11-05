# FlockOS public keys

Public certificates of the FlockOS RAUC PKI (ADR-0006, [docs/signing.md](../docs/signing.md))
and the public key of the release catalog (ADR-0009, [docs/release.md](../docs/release.md)).
The private keys never leave Cloud KMS.

| File | What | Valid |
|------|------|-------|
| `flockos-root-ca.pem` | root CA: the keyring of every release image (`/etc/rauc/keyring.pem`) | 20 years |
| `flockos-bundle-signer-<year>.pem` | bundle signer used by release runs | 3 years, renewed before expiry |

Created by `tools/rauc-pki/ceremony.sh` on 2026-11-05 (WP-0.5). Both keys are
RSA 4096 in Cloud KMS HSMs (project `record-1283`, `europe-west1`); the CA key
version is disabled between certificate issues.

| File | Subject | Valid until | SHA-256 fingerprint |
|------|---------|-------------|---------------------|
| `flockos-root-ca.pem` | `O=IronFlock, CN=FlockOS root CA` | 2046-11-05 | `13:77:58:08:56:70:A4:B7:69:9B:0F:F3:26:DD:75:00:BF:AA:77:BB:F7:05:20:6D:DF:32:B0:AF:01:49:D2:A7` |
| `flockos-bundle-signer-2026.pem` | `O=IronFlock, CN=FlockOS bundle signer 2026` | 2029-11-05 | `07:7C:67:FB:95:F5:42:0B:7E:0F:9A:82:5C:A4:EA:9C:A8:1B:70:91:7B:82:C7:51:94:98:0D:76:16:51:E0:B5` |

Check a copy with `openssl x509 -in <file> -noout -fingerprint -sha256` and the
chain with `openssl verify -CAfile flockos-root-ca.pem flockos-bundle-signer-2026.pem`.
Release builds trust the root CA, and `release.yml` signs their bundles with the
bundle signer (WP-1.6); every other build signs with throwaway keys.

## The catalog key

`flockos-catalog.pub` verifies the signed catalog `dl/flockos/manifest.json`
(ADR-0009). The device-agent checks the catalog with it (`FLOCKOS_CATALOG_PUBLIC_KEYS`),
and so does `release.yml` before it moves a release (`tools/catalog verify`).

| | |
|---|---|
| Key | `ironflock-release/flockos-catalog`, version 1: Ed25519 (`EC_SIGN_ED25519`), software protection, as the agent's `agent-update` key |
| Signer | only `flockos-release`, the release identity (`roles/cloudkms.signerVerifier` on this key) |
| Raw public key (base64, the agent's form) | `wFLa1T7iHYi20X8JVu/O6JUzBGmW2+tjo7QVMuxsmQg=` |
| SHA-256 of the DER public key | `e47e098ac89eefa24e62f607703063010c9f0b4e4c78243fe44f72be8d7a4927` |

Created by `tools/release-setup.sh` on 2026-11-05 (WP-2.6), with the publisher
identity `flockos-publisher`. Check a copy against Cloud KMS with
`gcloud kms keys versions get-public-key 1 --key flockos-catalog --keyring ironflock-release --location europe-west1 --project record-1283`,
and get the agent's form with
`openssl pkey -pubin -in flockos-catalog.pub -outform DER | tail -c 32 | base64`.
