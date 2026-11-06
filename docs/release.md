# Releasing FlockOS

A FlockOS release is the merge of a release pull request (`just release-patch`,
`just release-minor`, `just release-major`: a `VERSION` bump with the title
`release flockos v<version>`). Its push to `main` runs `release.yml`, which
builds every image, signs the bundles, tests the release image, publishes the
images and the signed catalog, and sets the tag last. Nothing is built, signed
or published from a laptop.

## The release run

| Job | What it does | Identity |
|-----|--------------|----------|
| `verify` | Decides what the run is: a release, a re-run after the tag, or a dry run (harness `release.sh mode`) | none |
| `build` | Every image as a release build (`build.yml`, `signing: release`): the images trust the FlockOS root CA, each bundle is sealed with a key of its build, each image gets its CycloneDX SBOM | none |
| `sign` | Re-signs every bundle with the bundle signer in Cloud KMS and checks it against the root CA (`build/sign-bundles.sh`, [signing.md](signing.md)); attests the SLSA provenance of every image and bundle | `flockos-release` |
| `e2e` | The release image of `amd64-efi base` in QEMU under KVM: first boot, enrollment from the test `.flock`, reboot, the update into slot B with its own KMS-signed bundle, the fallback (`test/qemu/run.py`, [testing.md](testing.md)) | none |
| `stage` | The signed files and one `SHA256SUMS` to `gs://ironflock-downloads/staging/flockos/<version>/` (`build/publish.sh stage`) | `flockos-publisher` |
| `promote` | The staged files to `gs://ironflock-downloads/flockos/<version>/`; a published file is never replaced by different bytes. Then the catalog, built on the published one and signed with the catalog key, to `flockos/manifest.json`, last. Then every file and the catalog must answer through the download proxy | `flockos-release` (the catalog), `flockos-publisher` (the files) |
| `tag` | The tag `v<version>` and the GitHub Release (harness `release-tag.yml`) | the release App |
| `assets` | `SHA256SUMS`, the SBOMs and the catalog on the GitHub Release; the images and bundles stay on the download server | the release App |
| `production` | Only in a manual run on a release tag: moves the production channel to that release (below) | `flockos-release`, `flockos-publisher` |

The workload identity pool gives the two FlockOS identities only to a push of
`release.yml` on `main` and to runs on `v*` tags. `flockos-publisher` can write
the two FlockOS trees of the download bucket and nothing else.

**The catalog.** `tools/catalog` builds `dl/flockos/manifest.json`
([manifest.schema.json](manifest.schema.json), ADR-0009):

- The release goes to the **test** channel. The first release is
  **production** too, as the schema requires a production release.
- `releases` keeps the versions a channel names and no others.
- The boards for FlockFlasher (`release/boards.json`) show production.
- `min_agent` is `CATALOG_MIN_AGENT` in `build/release.conf`.
- **Readers are forward-compatible.** They ignore fields they do not know. The
  device-agent looks up only its own image id, so other images' variants,
  kernels and architectures do not matter to it; FlockFlasher (from the release
  after v2.2.4) skips an image whose variant, kernel or architecture it does not
  know and keeps the rest of the catalog. A new
  variant (or kernel or architecture) is therefore a change in this repository
  only (the schema's enums, `tools/catalog`, `release/boards.json`); installed
  readers keep working and offer it once they know it. A change that would
  break a reader raises `schema`, which readers refuse.
- FlockFlasher (from the release after v2.2.4) reloads the catalog when its
  board list is shown, at most every five minutes, so a new release appears
  without restarting it.
- The catalog is signed in the device-agent's envelope with the Cloud KMS key
  `ironflock-release/flockos-catalog`. The tool verifies its own output, and
  `catalog verify -pubkey pki/flockos-catalog.pub manifest.json` checks a
  published one.

**Dry runs** run every job on release pull requests (`ci.yml` calls
`release.yml`) and on manual runs:

- `sign` uses a throwaway stand-in for the bundle signer.
- `e2e` boots and reboots only: no release image accepts a stand-in bundle.
- `stage` and `promote` print their storage calls (`DRY_RUN=1`).
- The catalog is signed with a throwaway key and verified.
- `tag` and `assets` are skipped.

## Moving a release to production

A release goes to the test channel. Once it has proven itself on test devices,
production moves to it, without a rebuild:

```sh
gh workflow run release.yml --ref v<version> -f promote-production=true
```

That run of `release.yml` on the release's tag (mode `tag`) runs only the
`production` job:

1. It reads the published catalog and verifies it with `pki/flockos-catalog.pub`.
2. It moves `production` to the tag's version, which must already be in the
   catalog: the same files, the same bundles. FlockFlasher's boards follow.
3. It signs the catalog with the catalog key as `flockos-release`.
4. It publishes the catalog as `flockos-publisher`.
5. It checks the catalog through the download proxy.

The pool gives both identities to runs on `v*` tags. Nothing else of
`release.yml` runs on a tag.

## Before the first release (once)

1. **The RAUC PKI:** `tools/rauc-pki/ceremony.sh --yes` ([signing.md](signing.md)).
   Done 2026-11-05.
2. **The catalog key and the publisher:** `tools/release-setup.sh --yes`, by a
   project owner on a branch. It creates the key, the `flockos-publisher`
   identity and its bucket permissions, and writes `pki/flockos-catalog.pub`
   for a pull request. Run it first without `--yes`: that shows every step and
   changes nothing. At the end it prints the line for step 4. Done
   2026-11-05 (`pki/flockos-catalog.pub`, [pki/README.md](../pki/README.md)).
3. **The download proxy** serves `gs://ironflock-downloads/flockos/` under
   `https://instance-registry.ironflock.com/dl/flockos/` (registry-proxy
   v0.2.9, 2026-11-05). Without it, `promote` would stop before the tag.
   Done.
4. **The device-agent** trusts the catalog key: the line from step 2 goes into
   `FLOCKOS_CATALOG_PUBLIC_KEYS` (device-agent `src/osupdate/catalog.go`), in
   an agent release. `CATALOG_MIN_AGENT` names that release: device-agent
   1.6.1 (#204).

## Not yet

- **The e2e on the platform.** The plan's end-to-end test enrolls the staged
  image into the test flock, checks it online through the API, and updates
  from the previous release to this one and back through the agent's
  `perform_os_update`. That needs the test flock's credentials in the
  `release` environment, and an agent with the catalog key on the images.
