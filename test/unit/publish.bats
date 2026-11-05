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
    printf 'not published' >"$tmp/out/$id/$id-1.0.0.ironflock.json"
  done
  printf 'bundle' >"$tmp/out/flockos-amd64-efi-base/flockos-amd64-efi-base-1.0.0.raucb"
}

teardown() { rm -rf "$tmp"; }

@test "sums lists every published file of every image, by name" {
  run bash "$publish" sums "$tmp/out"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = 9 ]
  [[ "$output" == *"  flockos-amd64-efi-base-1.0.0.raucb"* ]]
  [[ "$output" == *"  flockos-amd64-efi-installer-1.0.0.cdx.json"* ]]
  [[ "$output" != *"ironflock.json"* ]]
  [[ "$output" != *"/"* ]]
}

@test "stage uploads each file and SHA256SUMS to staging/flockos/<version>/, uncached" {
  DRY_RUN=1 run bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^+ gcloud storage cp')" = 10 ]
  [[ "$output" == *"gs://ironflock-downloads/staging/flockos/1.0.0/flockos-amd64-efi-base-1.0.0.raucb"* ]]
  [[ "$output" == *"gs://ironflock-downloads/staging/flockos/1.0.0/SHA256SUMS"* ]]
  [[ "$output" == *"--cache-control=public, max-age=0"* ]]
  [[ "$output" != *"gs://ironflock-downloads/flockos/"* ]]
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

@test "release.yml: the tag after the promotion, the promotion after the stage and the QEMU test" {
  [[ "$(needs e2e)" == *sign* ]]
  [[ "$(needs stage)" == *sign* ]]
  [[ "$(needs promote)" == *stage* && "$(needs promote)" == *e2e* ]]
  [[ "$(needs tag)" == *promote* ]]
  [[ "$(needs assets)" == *tag* ]]
}

@test "release.yml: only release runs authenticate, and only as the two FlockOS identities" {
  run grep -E 'service_account:' "$repo/.github/workflows/release.yml"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -v -E 'flockos-(release|publisher)@record-1283\.iam\.gserviceaccount\.com'
  # Every authentication step is guarded by the release mode.
  run awk '/uses: google-github-actions\/auth@/ { print prev } { prev = $0 }' "$repo/.github/workflows/release.yml"
  [ -n "$output" ]
  ! echo "$output" | grep -v "if: env.MODE == 'release'"
}
