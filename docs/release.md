# Releasing IronFlockOS

An IronFlockOS release is the merge of a release pull request (`just release-patch`,
`just release-minor`, `just release-major`: a `VERSION` bump with the title
`release ironflockos v<version>`). Its push to `main` runs `release.yml`, which
builds every image, signs the bundles, tests the release image, publishes the
images and the signed catalog, and sets the tag last. Nothing is built, signed
or published from a laptop.

## The release run

| Job | What it does | Identity |
|-----|--------------|----------|
| `verify` | Decides what the run is: a release, a re-run after the tag, or a dry run (harness `release.sh mode`) | none |
| `build` | Every image as a release build (`build.yml`, `signing: release`): the images trust the IronFlockOS root CA, each bundle is sealed with a key of its build, each image gets its CycloneDX SBOM | none |
| `sign` | Re-signs every bundle with the bundle signer in Cloud KMS and checks it against the root CA (`build/sign-bundles.sh`, [signing.md](signing.md)) | `ironflockos-release` |
| `attest` | The SLSA Build Level 3 provenance of every image and bundle as signed, by the harness's `attest-provenance.yml`, which runs none of this repository's code; `stage` waits for it | the harness workflow (Sigstore) |
| `e2e` | The release image of `amd64-efi base` in QEMU under KVM: first boot, enrollment from the test `.flock`, reboot, the update into slot B with its own KMS-signed bundle, the fallback (`test/qemu/run.py`, [testing.md](testing.md)) | none |
| `stage` | The signed files, each image's hardware list and one `SHA256SUMS` to `gs://ironflock-downloads/staging/ironflockos/<version>/` (`build/publish.sh stage`) | `ironflockos-publisher` |
| `sources` | The [source code](#source-code) of every package in the images: the files the pool `gs://ironflock-downloads/ironflockos/sources/` lacks go there, and the index `SOURCES` to the staging tree (`build/sources.sh plan`, `build/publish.sh sources`) | `ironflockos-publisher` |
| `promote` | The staged files to `gs://ironflock-downloads/ironflockos/<version>/`; a published file is never replaced by different bytes. Then the [release notes](#release-notes) to `ironflockos/release-notes.json`. Then the catalog, built on the published one and signed with the catalog key, to `ironflockos/manifest.json`, last. Then every file and the catalog must answer through the download proxy | `ironflockos-release` (the catalog), `ironflockos-publisher` (the files) |
| `vm-images` | The Compute Engine images of `amd64-efi base`, `amd64-efi nvidia` and `arm64-efi base`, each made from the published image into its image family `ironflockos-<target>-<variant>`, from which the virtual-device-manager creates IronFlockOS VMs (`build/gce-image.sh`, [ADR-0010](adr/0010-ironflockos-images-for-virtual-devices.md)) | `ironflockos-publisher` |
| `tag` | The tag `v<version>` and the GitHub Release (harness `release-tag.yml`) | the release App |
| `assets` | `SHA256SUMS`, the SBOMs and the catalog on the GitHub Release; the images and bundles stay on the download server | the release App |
| `production` | Only in a manual run on a release tag: moves the production channel to that release (below) | `ironflockos-release`, `ironflockos-publisher` |

The workload identity pool gives the two IronFlockOS identities only to a push of
`release.yml` on `main` and to runs on `v*` tags. `ironflockos-publisher` can write
the two IronFlockOS trees of the download bucket and make Compute Engine images named
`ironflockos-*`, and nothing else.

**The VM images.** An image is `ironflockos-<target>-<variant>-v<x-y-z>` in
`record-1283`, stored in `eu`, in the family `ironflockos-<target>-<variant>`. The
family serves the newest release, the test channel's. Its disk is the smallest
the IronFlockOS layout fits (10 GiB for base, 18 GiB for nvidia), so a product's
`minDiskSize_GB` must be at least that. The tarball Compute Engine reads goes to
`staging/ironflockos/<version>/gce/` and is removed once the image exists. A re-run
keeps an image made from the same file.

**The catalog.** `tools/catalog` builds `dl/ironflockos/manifest.json`
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
- **The installer stick carries every image of its target.** Its catalog entry
  lists them as `payloads` (image ids, from the build's `.payloads` file);
  FlockFlasher offers the stick for those variants and writes the chosen one as
  `payload=<image id>` into `installer.conf`. A new variant goes onto the stick
  through `INSTALLER_PAYLOADS` in its `target.conf`. Releases up to 0.10.0
  have no `payloads`: their sticks carry the base image only, and readers take
  it so.
- **The device-agent downloads a bundle from its own update base**, at
  `<update base>/ironflockos/<version>/<file>`, where `<file>` is the last part of
  the bundle's `url` (from device-agent 1.6.3). The `url`s
  name the copy on the download server; the catalog is signed, so no mirror
  can change them. On the cloud both are the same file. A device behind an
  IronFlock appliance reaches only the appliance, whose OS mirror serves the
  catalog unchanged and the bundles of the images its devices run, under the
  same paths. Size and sha256 still come from the signed catalog. The layout
  `ironflockos/<version>/<file>` is therefore part of the contract with readers.
- FlockFlasher (from the release after v2.2.4) reloads the catalog when its
  board list is shown, at most every five minutes, so a new release appears
  without restarting it.
- Each image names what `ironflock os install` needs of a disk
  ([below](#what-ironflock-os-install-reads)). Releases up to 0.14.0 do not.
- The catalog is signed in the device-agent's envelope with the Cloud KMS key
  `ironflock-release/ironflockos-catalog`. The tool verifies its own output, and
  `catalog verify -pubkey pki/ironflockos-catalog.pub manifest.json` checks a
  published one.

**Dry runs** run every job on release pull requests (`ci.yml` calls
`release.yml`) and on manual runs:

- `sign` uses a throwaway stand-in for the bundle signer.
- `e2e` boots and reboots only: no release image accepts a stand-in bundle.
- `stage` and `promote` print their storage calls (`DRY_RUN=1`).
- `sources` looks up every source package as a release does, so one without
  source fails the run, and prints its storage calls.
- `vm-images` makes each VM image's tarball and prints the cloud calls.
- The catalog is signed with a throwaway key and verified.
- `tag` and `assets` are skipped.

## What `ironflock os install` reads

`ironflock os install` of device-init (its ADR-0008) writes an image onto the
disk of a running machine. Besides an image's `url`, `sha256` and `size`, it
reads these fields of `releases.<version>.images.<image-id>` in the catalog.
Releases up to 0.14.0 have none of them.

| Field | What |
|-------|------|
| `image.raw_size` | The image decompressed, in bytes: what is written from the disk's first byte. |
| `image.min_disk_size` | The smallest disk, in bytes, on which the image becomes a working device: every partition of the device's layout, `/data` at 1 GiB, 2 MiB for the GPT ([build.md](build.md#the-smallest-disk)). At least `raw_size`; the installer's is its `raw_size`. |
| `modules_alias` | The image's hardware list, `url`, `sha256` and `size` of `<image-id>-<version>.modules.alias.gz`, published next to the image. |

Both sizes come from the build's `<image-id>-<version>.sizes`; `tools/catalog`
refuses a release image without them, and a catalog with only one of them or
with `min_disk_size` below `raw_size`.

**The hardware list** tells which devices the image's kernels have a driver
for. The build (`hardware_list` in `build/lib.sh`) writes, for each kernel,
after a comment line (`# kernel <version>: ...`):

- `alias <pattern> <module>` lines: the kernel's `modules.alias`, the drivers
  built as modules, as depmod writes them; then the `<module>.alias=<pattern>`
  records of `modules.builtin.modinfo`. On 6.12 those are only the aliases a
  built-in driver declares by name (`fs-ext4`), not those of its device
  table: a built-in driver such as `virtio_pci` has no `alias` line.
- `builtin <module>` lines: every driver built into the kernel, from its
  `modules.builtin` (`kernel/drivers/virtio/virtio_pci.ko` becomes
  `builtin virtio_pci`).

A kernel without one of the three files stops the build. One kernel on the
EFI targets; the Raspberry Pi image has two; Jetson, which has no disk image,
has no list. A device has a driver when its modalias (`/sys/.../modalias`,
such as `pci:v00008086d000015B8sv...`) matches an `alias` pattern by shell
rules (`*`, `?`, `[...]`), as modprobe matches them, after it has turned `-`
into `_` outside `[...]` in both; or, for a driver built into the kernel, when
the running machine's driver of the device (`/sys/.../driver/module`) has a
`builtin` line. The releases 0.15.0 and older have no `builtin` lines: their
lists miss the built-in drivers' device tables. `os install` matches the disk
controller and the network card. A match says nothing about a firmware file
the driver may need. Every disk image has one, the installer too; it is in
`SHA256SUMS`, and the signed catalog carries its hash. The SLSA provenance
covers the images and bundles, not it, as it does not cover the SBOMs
either.

## Release notes

`release-notes/<version>.md`, English Markdown for the people who run
devices, with the sections `## Security`, `## New`, `## Fixed` and
`## Changed`, in that order, the empty ones left out, and no heading of its
own (`just check-release-notes`, part of `just lint`). They are optional.
Commit the file before `just release-patch`: `promote` publishes every
file of the release's commit as `ironflockos/release-notes.json`
(`{version: markdown}`, `{}` without any; `build/publish.sh notes`) before
the catalog names the release. Moving production does not publish them.

When production moves to a release that has notes, the cloud emails it, with
its notes, to the members of every project with a device that runs IronFlockOS,
unless they switched off the System emails in their profile. A release
without notes sends no email; the next one with notes carries the notes
since the last email.

## Source code

This repository is under the Apache License 2.0. An image is a collection of
separate programs, each under its own licence, which
`/usr/share/doc/<package>/copyright` in the image names. Many are under the GPL
or LGPL (the kernel, GRUB, systemd, bash, RAUC), whose source has to be
available to everyone who gets the image. Each release therefore publishes the
source of every package in its images next to them:

- `customize.sh` records an image's source packages in
  `<image-id>-<version>.sources.tsv`: each package's source and the sources
  its `Built-Using` names. Debian keeps that field for licence compliance: the
  source of the signed kernel and GRUB is the unsigned `linux` and `grub2`.
- The `sources` job looks up every file of every source package with apt in
  the build container, from the source indexes of Debian and the Raspberry Pi
  archive. A version the archive no longer has comes from
  snapshot.debian.org. Each file must have the hash of the archive's signed
  index (or snapshot's).
- The packages from Docker's and NVIDIA's repositories have no source packages.
  [`release/sources`](../release/sources) decides each one: the upstream
  tarball (`nvidia-modprobe`, the NVIDIA kernel modules the build makes), or
  no source, with the reason (Apache-2.0, MIT, NVIDIA's binary driver).
  A source package in neither the archives nor that file fails the release,
  so a new repository needs a decision there first.
- The files go to the pool `ironflockos/sources/<archive>/<source>/<file>`
  (`debian`, `raspberrypi`, `upstream`), which every release shares: a file
  there is never replaced, and only new ones are uploaded. The first release
  uploads about 1.7 GB.
- `ironflockos/<version>/SOURCES` lists every file of the release, with the
  reason for each package without source. `dget <URL of a .dsc>` fetches a
  Debian source package. `check` makes sure `SOURCES` and the pool answer
  through the download proxy.
- Each image says where `SOURCES` is in `/usr/share/doc/ironflockos/copyright`, so
  a copy that is passed on carries the directions too.
- Releases up to 0.11.0 have no `SOURCES`: their images record no source
  packages.

## Moving a release to production

A release goes to the test channel. Once it has proven itself on test devices,
production moves to it, without a rebuild:

```sh
just promote production [<version>]
```

Without a version it takes the one on the test channel. It shows the move, asks
before it goes on, and starts this run:

```sh
gh workflow run release.yml --ref v<version> -f promote-production=true
```

That run of `release.yml` on the release's tag (mode `tag`) runs only the
`production` job:

1. It reads the published catalog and verifies it with `pki/ironflockos-catalog.pub`.
2. It moves `production` to the tag's version, which must already be in the
   catalog: the same files, the same bundles. FlockFlasher's boards follow.
3. It signs the catalog with the catalog key as `ironflockos-release`.
4. It publishes the catalog as `ironflockos-publisher`.
5. It checks the catalog through the download proxy.

The pool gives both identities to runs on `v*` tags. Nothing else of
`release.yml` runs on a tag.

## Before the first release (once)

1. **The RAUC PKI:** `tools/rauc-pki/ceremony.sh --yes` ([signing.md](signing.md)).
   Done 2026-11-05 under the old names, again 2026-11-11 under the names of ADR-0017.
2. **The catalog key and the publisher:** `tools/release-setup.sh --yes`, by a
   project owner on a branch. It creates the key, the `ironflockos-publisher`
   identity and its bucket permissions, and writes `pki/ironflockos-catalog.pub`
   for a pull request. Run it first without `--yes`: that shows every step and
   changes nothing. At the end it prints the line for step 5. Done
   2026-11-11 (`pki/ironflockos-catalog.pub`, key id `036ef3bd`, [pki/README.md](../pki/README.md)).
3. **The download proxy** serves `gs://ironflock-downloads/ironflockos/` under
   `https://instance-registry.ironflock.com/dl/ironflockos/` (registry-proxy,
   the release after its `ironflockos-names` branch). Without it, `promote` would stop
   before the tag. Open: until then only `dl/flockos/` is served.
4. **The VM images:** `tools/release-setup.sh --yes` again, after it has gained
   the role `ironflockosVmImagePublisher` (ADR-0010). It keeps everything that
   exists and adds the role and its binding for `ironflockos-publisher`. Until
   then `vm-images` fails, and with it the tag; re-run the failed jobs after
   it.
5. **The device-agent** trusts the catalog key: the line from step 2 goes into
   `IRONFLOCKOS_CATALOG_PUBLIC_KEYS` (device-agent `src/osupdate/catalog.go`), in
   an agent release. `CATALOG_MIN_AGENT` names that release: device-agent
   1.6.1 (#204).

## Not yet

- **The e2e on the platform.** The plan's end-to-end test enrolls the staged
  image into the test flock, checks it online through the API, and updates
  from the previous release to this one and back through the agent's
  `perform_os_update`. That needs the test flock's credentials in the
  `release` environment, and an agent with the catalog key on the images.
- **The source code of Jetson images.** `build/sources.sh` knows Debian and the
  Raspberry Pi archive, not Ubuntu or NVIDIA's L4T repositories. Jetson's
  sources (Ubuntu's source packages, NVIDIA's `public_sources.tbz2`) come with
  its licence compliance, WP-6.8 ([jetson-licence-review.md](jetson-licence-review.md)),
  before the first Jetson release.
