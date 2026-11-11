# ADR-0019: Every test runs before the merge; the release run only releases

Status: accepted, 2026-11-11. Builds on
[ADR-0018](0018-the-release-reuses-the-dry-runs-images.md).

## Context

The rule: every test runs in the pull request's CI, before the merge into
`main`, so a fault is found before it reaches `main`. The release run after
the merge only releases. It reuses the images that the pull request built
(ADR-0018) and signs, attests, stages, publishes the source code, promotes,
makes the VM images, tags and attaches the assets.

A release pull request's CI tests:

- the gate (lint and unit tests) and the Go tools;
- every image as a development build (`signing: dev`) in QEMU, with the whole
  sequence of `test/qemu/run.py`: first boot, reboot, the update into slot B
  with the bundle of the same build, the factory reset, the fallback and the
  crash; both installer sticks; `rpi-check` for the Raspberry Pi;
- `release.yml` as a dry run: the release build of every image, its bundles
  signed by a throwaway stand-in for the bundle signer, and `e2e`, in which
  the release image of `amd64-efi base` boots and reboots in QEMU with Secure
  Boot on (`--only boot`).

The release run had one test of its own, `e2e`: the whole sequence on the
release image of `amd64-efi base`, with the bundle that Cloud KMS had just
signed. Every other job of the release run is a release step. Some of them
check something before they publish: the proof in `source`, the file and
signature checks in `sign`, the catalog's signature and the check through the
download proxy in `promote`, the checksums in `vm-images`. `release-ok`
checks at the end that every job ran or was skipped as it must. Those checks
stay.

The dry run boots only because the update needs a bundle the image accepts.
A release image trusts the IronFlockOS root CA and nothing else, and only the
bundle signer in Cloud KMS signs under it. No pull request run may reach that
signer (ADR-0006, ADR-0018). The dry run therefore signs with a stand-in, and
every release image refuses the stand-in's bundles, on purpose
(`build/sign-bundles.sh` checks it). Every step after the reboot needs the
update: the factory reset starts on slot B, the fallback installs the bundle
again, the crash needs two good slots.

## Decision

### Before the merge

Every test runs in the release pull request's CI, as listed above. The dry
run's `sign` also checks each bundle against the keyring its image carries
(below): the stand-in's bundle must be refused, and the bundle signer's
certificate must chain to that keyring.

### After the merge

A release run that reuses its pull request's images only releases them:
`source`, `sign`, `attest`, `stage`, `sources`, `promote`, `vm-images`,
`tag` and `assets`. It skips `e2e`. The pull request tested those images.

`sign` checks the release signature against the image itself, without a VM.
After the Cloud KMS signature, `build/verify-bundles.sh` unpacks the disk
image next to each bundle, reads `/etc/rauc/keyring.pem` from slot A (the
partition `rootfs-a`) with debugfs, and verifies the bundle against that
keyring as a device does: with the code-signing purpose and the signing
time. A bundle that does not verify stops the release before `stage`. This
is the part of the old `e2e` that only the release signature can show.

### The fall-back

A release run that builds its images itself runs `e2e` as before: the whole
sequence with its own signed bundle, before `promote`. That happens when the
switch `IRONFLOCKOS_REUSE` is off, when the lookup fails, and when `source`
fails or is cancelled. Nobody has tested those images, and images that
nobody tested are never published.

### The job graph

`e2e` runs under the same condition as `build`. `promote` takes a skipped
`e2e` only in a run that reused its images, and a successful one only in a
run that built them. `release-ok` (`build/release-check.sh`) fails a run that
reused its images and ran `e2e`, and a run that built its images and skipped
it.

## What stays untested before the merge

- **The update of a release image.** When the release reuses its images, no
  release image installs a bundle in a VM before devices can get the
  release. The update into slot B, the factory reset, the fallback and the
  crash run only on the development builds of the same tree, which trust a
  throwaway CA of their own build. The release image of `amd64-efi base`
  boots and reboots, nothing more.
- **The release signature in a VM.** The Cloud KMS signature exists only after
  the merge. `verify-bundles.sh` shows that each image's keyring accepts it
  as RAUC checks it, but not that an installation with it succeeds.
- **The other release images.** Only `amd64-efi base` boots as a release
  build. The release builds of `amd64-efi nvidia`, `arm64-efi`, the `rt`
  images, the Raspberry Pi and the installer sticks are not booted at all; it
  was so before this decision as well. Their development builds are tested
  in full.
- **Two builds.** A pull request's development build and its release build
  are two builds of the same tree. Packages follow the archive at build time,
  so the two can differ when the archive changes between them.

## Consequences

- A release that reuses its images no longer waits for the QEMU test after
  the merge.
- A release that builds its images takes as long as before.
- `sign` unpacks each image once more, on the runner's second disk, to read
  its keyring. A dry run does the same, so a fault in that check shows on the
  pull request.
- A fault that shows only with the release keyring and a bundle signed in
  Cloud KMS reaches the test channel and the VM image families before anyone
  sees it. Production moves later, by hand, once the release has proven
  itself on test devices ([release.md](../release.md)).

## Alternatives

- **Keep `e2e` after the merge for every release.** It is the only test of an
  update with a release bundle on a release image. But it is a test after the
  merge, which the rule excludes.
- **Sign in the pull request with the Cloud KMS signer.** The signer would sign
  what any pull request's run built. Rejected (ADR-0006, ADR-0018).
- **A test signer under the root CA for pull requests.** Every device would
  accept what a pull request can sign. Rejected.
- **A test copy of the image that trusts the stand-in.** It would no longer be
  the image that is released, and it would show nothing about the release
  signature.
- **The previous release's bundle.** It carries the release signature, but the
  steps after the update would then run the previous release, not this one.
  The bundles of 0.15.0 and older do not fit the images after the rename
  either ([ADR-0017](0017-every-name-is-ironflockos.md)).
