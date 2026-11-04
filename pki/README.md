# FlockOS RAUC certificates

Public certificates of the FlockOS RAUC PKI (ADR-0006, [docs/signing.md](../docs/signing.md)).
The private keys never leave Cloud KMS.

| File | What | Valid |
|------|------|-------|
| `flockos-root-ca.pem` | root CA: the keyring of every release image (`/etc/rauc/keyring.pem`) | 20 years |
| `flockos-bundle-signer-<year>.pem` | bundle signer used by release runs | 3 years, renewed before expiry |

They are created once by `tools/rauc-pki/ceremony.sh` (WP-0.5); until then
release signing is not available and every build signs with throwaway keys.
