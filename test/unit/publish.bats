#!/usr/bin/env bats
# Publishing a release (WP-2.6, docs/release.md): what build/publish.sh
# uploads where (dry runs), the pins it reads, and the order of the release
# jobs.

repo="$BATS_TEST_DIRNAME/../.."
publish="$repo/build/publish.sh"

setup() {
  tmp=$(mktemp -d)
  for id in flockos-amd64-efi-base flockos-amd64-efi-installer; do
    mkdir -p "$tmp/out/$id"
    printf 'image' >"$tmp/out/$id/$id-1.0.0.img.gz"
    printf 'osr' >"$tmp/out/$id/$id-1.0.0.os-release"
    printf 'pkgs' >"$tmp/out/$id/$id-1.0.0.packages.tsv"
    printf '{}' >"$tmp/out/$id/$id-1.0.0.cdx.json"
    printf 'aliases' >"$tmp/out/$id/$id-1.0.0.modules.alias.gz"
    printf 'not published' >"$tmp/out/$id/$id-1.0.0.ironflock.json"
    printf 'raw_size=1\nmin_disk_size=1\n' >"$tmp/out/$id/$id-1.0.0.sizes"
  done
  printf 'bundle' >"$tmp/out/flockos-amd64-efi-base/flockos-amd64-efi-base-1.0.0.raucb"
}

teardown() { rm -rf "$tmp"; }

@test "sums lists every published file of every image, by name" {
  run bash "$publish" sums "$tmp/out"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = 11 ]
  [[ "$output" == *"  flockos-amd64-efi-base-1.0.0.raucb"* ]]
  [[ "$output" == *"  flockos-amd64-efi-installer-1.0.0.cdx.json"* ]]
  # The hardware list, which the catalog names; the sizes are in the catalog.
  [[ "$output" == *"  flockos-amd64-efi-base-1.0.0.modules.alias.gz"* ]]
  [[ "$output" != *"ironflock.json"* ]]
  [[ "$output" != *".sizes"* ]]
  [[ "$output" != *"/"* ]]
}

@test "stage uploads each file and SHA256SUMS to staging/flockos/<version>/, uncached" {
  DRY_RUN=1 run bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^+ gcloud storage cp')" = 12 ]
  [[ "$output" == *"gs://ironflock-downloads/staging/flockos/1.0.0/flockos-amd64-efi-base-1.0.0.raucb"* ]]
  [[ "$output" == *"gs://ironflock-downloads/staging/flockos/1.0.0/SHA256SUMS"* ]]
  [[ "$output" == *"--cache-control=public, max-age=0"* ]]
  [[ "$output" != *"gs://ironflock-downloads/flockos/"* ]]
  [[ "$output" == *"dry run, nothing changed: would have staged 11 files"* ]]
}

@test "stage refuses a directory without release files" {
  mkdir "$tmp/empty"
  DRY_RUN=1 run bash "$publish" stage "$tmp/empty" 1.0.0
  [ "$status" -ne 0 ]
}

@test "promote copies staging to the live tree; the catalog goes to flockos/manifest.json" {
  DRY_RUN=1 run bash "$publish" promote 1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"gs://ironflock-downloads/staging/flockos/1.0.0/* gs://ironflock-downloads/flockos/1.0.0/"* ]]
  printf '{}' >"$tmp/manifest.json"
  DRY_RUN=1 run bash "$publish" catalog "$tmp/manifest.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gs://ironflock-downloads/flockos/manifest.json"* ]]
}

@test "notes publishes release-notes/<x.y.z>.md as flockos/release-notes.json, uncached" {
  mkdir "$tmp/notes"
  printf '## New\n\n- A feature.\n' >"$tmp/notes/0.11.0.md"
  printf '## Fixed\n\n- A bug.\n' >"$tmp/notes/0.12.0.md"
  DRY_RUN=1 run bash "$publish" notes "$tmp/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ gcloud storage cp --quiet --cache-control=public, max-age=0 "*" gs://ironflock-downloads/flockos/release-notes.json"* ]]
  [[ "$output" == *"would have published the release notes of 2 version(s)"* ]]
}

@test "notes publishes {} without release notes, also when the directory is missing" {
  DRY_RUN=1 run bash "$publish" notes "$tmp/missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gs://ironflock-downloads/flockos/release-notes.json"* ]]
  [[ "$output" == *"the release notes of 0 version(s)"* ]]
}

@test "notes refuses a file that is not <x.y.z>.md" {
  mkdir "$tmp/notes"
  printf '## New\n\n- A.\n' >"$tmp/notes/next.md"
  DRY_RUN=1 run bash "$publish" notes "$tmp/notes"
  [ "$status" -ne 0 ]
  [[ "$output" == *"next.md: the name must be <x.y.z>.md"* ]]
  [[ "$output" != *"gcloud storage cp"* ]]
}

@test "release.yml: the release notes before the catalog" {
  wf="$repo/.github/workflows/release.yml"
  notes=$(grep -n 'build/publish.sh notes release-notes' "$wf" | cut -d: -f1)
  # The release's catalog (the production job publishes one too, later).
  catalog=$(grep -n 'build/publish.sh catalog manifest.json' "$wf" | head -n 1 | cut -d: -f1)
  [ -n "$notes" ] && [ -n "$catalog" ]
  [ "$notes" -lt "$catalog" ]
}

@test "usage errors" {
  run bash "$publish"
  [ "$status" -ne 0 ]
  run bash "$publish" stage
  [ "$status" -ne 0 ]
  run bash "$publish" promote
  [ "$status" -ne 0 ]
}

@test "the publishing pins are complete" {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/build/release.conf"
  [ "$BUCKET" = gs://ironflock-downloads ]
  [[ "$DL_BASE" == https://* ]]
  [[ "$CATALOG_KMS_KEY" =~ ^projects/[a-z0-9-]+/locations/[a-z0-9-]+/keyRings/ironflock-release/cryptoKeys/flockos-catalog/cryptoKeyVersions/[0-9]+$ ]]
  [[ "$CATALOG_MIN_AGENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# needs JOB: the needs of a job of release.yml.
needs() {
  awk -v job="  $1:" '$0 == job { f = 1; next } f && /^  [a-z][a-z-]*:$/ { exit } f && /^    needs:/ { print; exit }' \
    "$repo/.github/workflows/release.yml"
}

@test "release.yml: the tag after the promotion and the VM images, the promotion after the stage and the QEMU test" {
  [[ "$(needs e2e)" == *sign* ]]
  [[ "$(needs stage)" == *sign* ]]
  [[ "$(needs promote)" == *stage* && "$(needs promote)" == *e2e* ]]
  # the release's source code, staged before the promotion publishes it
  [[ "$(needs sources)" == *stage* ]]
  [[ "$(needs promote)" == *sources* ]]
  [[ "$(needs tag)" == *promote* ]]
  # the VM images of a published release, before the tag
  [[ "$(needs vm-images)" == *promote* ]]
  [[ "$(needs tag)" == *vm-images* ]]
  [[ "$(needs assets)" == *tag* ]]
}

@test "release.yml: only release runs authenticate, and only as the two IronFlockOS identities" {
  run grep -E 'service_account:' "$repo/.github/workflows/release.yml"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -v -E 'flockos-(release|publisher)@record-1283\.iam\.gserviceaccount\.com'
  # Every authentication step is guarded by the release mode, but in the
  # production job, which runs on a release tag only.
  run awk '/^  [a-z][a-z-]*:$/ { job = $1 } /uses: google-github-actions\/auth@/ && job != "production:" { print prev } { prev = $0 }' \
    "$repo/.github/workflows/release.yml"
  [ -n "$output" ]
  ! echo "$output" | grep -v "if: env.MODE == 'release'"
  grep -q "if: needs.verify.outputs.mode == 'tag' && inputs.promote-production" "$repo/.github/workflows/release.yml"
}

@test "release.yml: a run on a tag builds nothing" {
  for job in build sign e2e stage sources promote vm-images; do
    run awk -v job="  $job:" '$0 == job { f = 1; next } f && /^  [a-z][a-z-]*:$/ { exit } f && /^    if:/ { print; exit }' \
      "$repo/.github/workflows/release.yml"
    [[ "$output" == *"mode == 'release' || needs.verify.outputs.mode == 'dry-run'"* ]] || { echo "$job: $output"; return 1; }
  done
}
