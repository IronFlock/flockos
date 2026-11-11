# Signing IronFlockOS update bundles

How RAUC bundles are signed and verified (ADR-0006). No private key exists on
a runner, a laptop or in this repository.

## The PKI

| Object | Where | Used by |
|--------|-------|---------|
| Root CA key | Cloud KMS `record-1283/europe-west1/ironflockos-rauc-ca/root`, HSM, RSA 4096 PKCS#1 SHA-256 | a project owner, once, and every three years to issue a signer certificate; its key version stays disabled in between |
| Root CA certificate | [`pki/ironflockos-root-ca.pem`](../pki/), 20 years | every release image as `/etc/rauc/keyring.pem` |
| Bundle signer key | Cloud KMS `record-1283/europe-west1/ironflockos-rauc/bundle-signer`, HSM, RSA 4096 PKCS#1 SHA-256 | release runs of `release.yml`, through PKCS#11 |
| Bundle signer certificate | `pki/ironflockos-bundle-signer-<year>.pem`, 3 years, code signing only | embedded in every release bundle |
| Release identity | service account `ironflockos-release@record-1283` | only `release.yml` on a push to `main` or a `v*` tag of IronFlock/ironflockos (workload identity attribute `release=<repo id>:release`, the mapping the CLI's signer uses) |

RSA 4096 with SHA-256 rather than EC P-384: RAUC signs SHA-256 digests, and a
Cloud KMS key accepts only the digest of its own algorithm. HSM protection:
the root CA is in the keyring of every device for twenty years.

The two keys sit in two key rings because Google's PKCS#11 library lists every
key of the ring it is pointed at: the release identity can list and use the
signer ring and nothing else, so it can never sign with the CA, whatever a
later IAM change on the CA ring looks like.

Devices trust the CA, not the signer: a new signer certificate needs no device
update. RAUC checks the chain with `check-purpose=codesign` and at the bundle's
signing time (`use-bundle-signing-time=true`), because Raspberry Pis have no
real-time clock.

## Creating the PKI (once, WP-0.5)

A project owner runs, on a branch of this repository:

```sh
gcloud auth application-default login     # rauc-pki signs as these credentials
tools/rauc-pki/ceremony.sh                # shows every step, changes nothing
tools/rauc-pki/ceremony.sh --yes          # creates rings, keys, identity; issues both certificates
```

The script is idempotent. It creates the two HSM keys, the `ironflockos-release`
service account with `roles/cloudkms.signerVerifier` on the signer key and
`roles/cloudkms.viewer` on its ring, binds the workload identity, issues the
root CA certificate and the signer certificate with `tools/rauc-pki` (a small Go
program that has KMS sign the certificates; only SHA-256 digests leave the
machine), disables the CA key version, and verifies the chain with `openssl`.
The two certificates then go into `pki/` with a pull request. IAM can take a
minute to know a service account it has just created; the script retries the
bindings for two minutes, and a run that stops anyway is simply run again.

Done on 2026-11-05 under the old names, and again on 2026-11-11 under the names of
ADR-0017: the certificates and their fingerprints are in [`pki/`](../pki/README.md).

## How a release run signs (WP-1.6)

`release.yml` builds and signs in separate jobs, so the job that downloads and
runs the build's packages never holds the release identity:

1. **`build`** (`build.yml` with `signing: release`) builds every image.
   `build/signing.sh release` puts the root CA into the image as
   `/etc/rauc/keyring.pem` and seals each bundle with a throwaway key made for
   that build. The sealing CA travels next to the bundle as
   `<name>.seal-ca.pem`. A release reuses this build from its pull request's
   dry run when it can prove that run built the release commit's tree, and
   builds otherwise ([ADR-0018](adr/0018-the-release-reuses-the-dry-runs-images.md),
   [release.md](release.md#reused-images)). The signer then signs a build of
   a `pull_request` run, bound to the release commit by the harness's
   attestation of the build's manifest and by the trees; each `sign` job
   checks every file of its image against that manifest before it signs.
2. **`sign`** (one job per image) is the only job that authenticates as
   `ironflockos-release`, and only on a release. `build/sign-in-builder.sh` runs
   `build/sign-bundles.sh` in the build container. The script fetches Google's PKCS#11 library at the version
   in `build/release.conf`, checks the tarball's SHA-256 and the library's
   signature (Google's key in `build/keys/`), and writes the library's config
   (mode 0600):

   ```yaml
   tokens:
     - key_ring: projects/record-1283/locations/europe-west1/keyRings/ironflockos-rauc
       label: ironflockos-rauc
   ```

   Each bundle is checked against its sealing CA, then re-signed with the
   payload unchanged:

   ```sh
   export RAUC_PKCS11_MODULE=/path/to/libkmsp11.so
   rauc --conf=<the sealing CA> resign --signing-keyring=pki/ironflockos-root-ca.pem \
     --cert=pki/ironflockos-bundle-signer-<year>.pem \
     --key='pkcs11:token=ironflockos-rauc;object=bundle-signer' sealed.raucb signed.raucb
   ```

   The signed bundle must verify as the device verifies it: against the root
   CA, with `check-purpose=codesign` and the signing time. It must not verify
   against the sealing CA any more. `SHA256SUMS` is rewritten.
   The `attest` job then attests the SLSA build provenance of every image and
   bundle (Build Level 3). It is the harness's `attest-provenance.yml`, which
   runs none of this repository's code. `sign` holds a workload identity and
   runs this repository's scripts, but its token names `release.yml`, so a
   check pinned to the harness workflow refuses anything it could attest.
3. `tag` runs only after `sign`, so a tag always means signed bundles.

The object is addressed by label (the key's name), not by id: OpenSC's libp11
limits ids to 100 characters, which a KMS key version name exceeds. The newest
`pki/ironflockos-bundle-signer-*.pem` signs; a certificate within 30 days of its
expiry stops the release (see renewal below).

**Dry runs** (`release.yml` on release pull requests through `ci.yml`, and
manual runs) build exactly like a release. The sign step then uses a
throwaway stand-in for the bundle signer, and the release's provenance is not
attested. On a release pull request the harness attests the manifest of the
build, which the release run checks before it reuses the images. Each dry-run
bundle is checked to verify against the stand-in and not against the root CA.
The workload identity is not available to them: the pool grants
`release=<repo id>:release` only to a push of `release.yml` on `main` and to
runs on `v*` tags. A release's signature is therefore first seen on the release
run itself; `just sign-bundles dry-run` runs the same steps locally on a
release build (`IRONFLOCKOS_SIGNING=release just build …`).

## Pull requests and local builds

Every other build signs with a throwaway CA and signer made by
`build/signing.sh` and discarded with the build. Its image trusts only that
throwaway CA, so a pull-request image never installs a release bundle and a
release image never a pull-request bundle.

## Renewing the signer certificate (every three years)

1. Enable the CA key version:
   `gcloud kms keys versions enable 1 --key root --keyring ironflockos-rauc-ca --location europe-west1 --project record-1283`.
2. Add a key version to `bundle-signer` if the old key is to be retired as
   well, or reuse version 1.
3. Issue `pki/ironflockos-bundle-signer-<year>.pem` with
   `go -C tools/rauc-pki run . issue …` (see `ceremony.sh` for the flags).
4. Disable the CA key version again; open a pull request with the new
   certificate; `release.yml` uses the newest `pki/ironflockos-bundle-signer-*.pem`.

Devices need nothing: the CA in their keyring verifies the new signer.

## Retired keys

The 2021 and 2025 ReswarmOS certificates and the key committed to the archived
`IronFlock/flockos-buildroot-legacy` are never used again; `gs://reswarmos-certs`
is empty. IronFlockOS devices do not trust them.
