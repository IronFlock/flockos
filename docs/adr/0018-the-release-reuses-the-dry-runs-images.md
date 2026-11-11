# ADR-0018: The release reuses the images of its pull request's dry run

Status: accepted, 2026-11-11.

## Context

A release pull request's CI runs `release.yml` as a dry run. Its `build` is
the same release build as the release run's (`build.yml`, `signing: release`):
the same workflow files and scripts, the same tree. The release run then
built every image a third time after the merge, for about 15 of its 72
minutes.

Until now the bundle signer in Cloud KMS signed only what the release run on
`main` built itself (ADR-0006, [signing.md](../signing.md)). The repository is
public, and that signature is what every device trusts. Taking images from
another run must therefore not let anything else reach the signer: not a run
of another pull request, not a run whose workflow files came from another
base branch, not an earlier commit of the same pull request, not a fork's
run, not another workflow or event, and not a claim an artifact makes about
itself.

## Decision

The release run takes the images of its pull request's dry run when it can
prove that this run built the release commit's tree. Otherwise it builds them
as before. Anything it cannot prove, and any error, means a build, never a
failed release. The job summary says which way it went and why.

### The switch and the fall-back

- The lookup runs only while the repository variable `IRONFLOCKOS_REUSE` is
  `true`. Anything else, the variable unset included, is a build. The dry
  run's `attest-build` and `would-reuse` run regardless, so a release pull
  request shows whether its images could be reused.
- Each step of the lookup has a timeout (10 minutes for the lookup, 20 for
  the download, 10 for the file check, 5 for keeping the verified manifest)
  and may fail; any failure is a build. The job's timeout (60 minutes) is
  above their sum.
- When the `source` job fails all the same, `build` runs and `sign` takes the
  built images. The run ends red for the failed job, but the release is made.
- Once `source` has decided to reuse, there is no way back: a `sign` job whose
  download fails (20 minutes at most) or whose files differ from the manifest
  fails the release, before it signs anything. A re-run of the release run
  looks up again and builds when the lookup no longer holds.

### The evidence

- **The manifest.** Each image build lists every file it leaves, with sha256
  and size (`build/reuse.sh list`). The dry run joins the lists into one
  manifest, `build.tsv` (`build/reuse.sh manifest`).
- **Its attestation.** On a release pull request the harness's
  `attest-provenance.yml@v1` attests `build.tsv` in the dry run (`attest-build`).
  The harness runs none of this repository's code. Its Sigstore certificate
  carries GitHub's OIDC claims of that job: the signer workflow, the event, the
  top-level workflow and its ref, the run and attempt, the runner, and the
  commit the run checked out. The artifact cannot change any of them.

### The binding (`build/reuse.sh find`, in the release run's `source` job)

1. The pull request: the API's pull requests of the release commit; exactly
   one is merged with this commit as its merge commit, into `main`, from this
   repository (no fork).
2. The run: the newest successful run of `.github/workflows/ci.yml` for event
   `pull_request` on that pull request's head, from this repository.
3. Its artifacts: the manifest and every image of `RELEASE_IMAGES`, each
   exactly once, none expired, none expiring within 6 hours, none older than
   24 hours.
4. The manifest: one `build.tsv`, well-formed, naming exactly the release's
   images.
5. Its attestation (`gh attestation verify`): signed by
   `IronFlock/workflows/.github/workflows/attest-provenance.yml@refs/tags/v1`
   (exact identity), GitHub's OIDC issuer, ref `refs/pull/<n>/merge`, a
   GitHub-hosted runner; and in the certificate: event `pull_request`,
   top-level workflow `ci.yml@refs/pull/<n>/merge`, run `<run id>`, this
   repository. Exactly one commit: the merge commit the run built.
6. The tree: that commit's tree, from the API, is the release commit's tree.
   Squash merges and the rule that a pull request must be up to date with
   `main` make them equal; the check does not assume it.
7. The files: every image of the run is downloaded and must hold exactly the
   manifest's files, byte for byte (`build/reuse.sh files`). Each `sign` job
   checks its image again against the verified manifest before it signs.

Equal trees mean the run ran this commit's workflow files and scripts: the
dry run's build is the release run's build, started earlier.

### What a reused image names

`BUILD_ID` and `SOURCE_DATE_EPOCH` name a commit. In a pull request's run
`HEAD` is GitHub's test merge, which GitHub drops after the merge. CI on a
pull request therefore names the pull request's head when it has the same
tree (`build_commit` in `build/lib.sh`); GitHub keeps it as
`refs/pull/<n>/head`. A reused image names the head commit of its release pull
request and its time; a built one names the release commit, as before. The
catalog's `build_id`, the bundle's `build=`, `os-release` and what the
`ironflock` CLI shows follow. The release's tag, `SOURCES` and VM images do
not use the commit.

### The dry run checks the same path

On a release pull request the dry run attests its manifest and then runs the
same check on its own run (`would-reuse`: `build/reuse.sh check` and
`files`). A manifest or an attestation that would not verify fails the dry
run. Its `sign` jobs take their images through the same download and file
check.

## Consequences

- A release run that reuses skips its build: about 15 minutes less.
- The release signs images built in a `pull_request` run. That run had the
  same code, but it is not the release run itself. The binding rests on
  GitHub's word: its API (pull request, run, trees, artifacts) and its OIDC
  claims in the attestation's certificate.
- The bytes come from a larger run than the release run. Besides the release
  build, the pull request's run holds the gate, the workflow lint, the
  intent, the dev builds, the QEMU tests and rpi-check. Every job of a run can
  upload artifacts, and an upload that overwrites can replace one. A job of
  that run that is compromised (through the harness's tools, a package of a
  dev build, or the runner) could, in principle, replace a `release-image-*`
  artifact and its file list before `manifest` and `attest-build` run, and the
  attestation would then vouch for the replaced bytes. In the release run
  only the build jobs could do that. The fix, for later: the release dry run
  as a `pull_request` workflow of its own that runs only the release build,
  with the reuse check pinning `buildConfigURI` to that workflow instead of
  `ci.yml`.
- The images hold the packages of the pull request's run, at most 24 hours
  old, not of the merge. A fix published in between comes with the next
  release.
- Re-running the pull request's CI between the release's `source` and `sign`
  jobs can leave two artifacts of one name in that run. `sign` then refuses
  the files and the release fails without signing anything; a re-run of the
  release builds.
- The SLSA provenance of the release (`attest`) names the release run, also
  for reused images: release.yml on main, as the builder of bytes a pull
  request's run built. The dry run's attestation of the manifest stays in the
  repository's attestations and names the run that built them
  ([signing.md](../signing.md)).
- A manual dry run (`workflow_dispatch`) neither attests nor checks reuse: it
  has no pull request.

## Alternatives

- **Build in the release run only** (as before): the safest, and 15 minutes
  slower.
- **Bind by the API alone**, without an attestation: the API does not say
  which merge commit a `pull_request` run checked out, and a run for the same
  head in a pull request into another base branch runs that branch's
  workflow files. The certificate says it.
- **Trust the images' own `BUILD_ID`**: an artifact's claim about itself.
- **Attest every image file instead of the manifest**: the harness would
  download all of them (11.5 GiB) in the dry run; the manifest binds them as
  well, and the release run hashes every file anyway.
