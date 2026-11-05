# FlockOS RAUC certificates

Public certificates of the FlockOS RAUC PKI (ADR-0006, [docs/signing.md](../docs/signing.md)).
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
Until release signing is wired into `release.yml` (WP-1.6), every build still
signs with throwaway keys.
