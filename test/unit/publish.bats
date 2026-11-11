#!/usr/bin/env bats
# Publishing a release (WP-2.6, docs/release.md): what build/publish.sh
# uploads where (dry runs), the pins it reads, and the order of the release
# jobs.

repo="$BATS_TEST_DIRNAME/../.."
publish="$repo/build/publish.sh"

setup() {
  tmp=$(mktemp -d)
  for id in ironflockos-amd64-efi-base ironflockos-amd64-efi-installer; do
    mkdir -p "$tmp/out/$id"
    printf 'image' >"$tmp/out/$id/$id-1.0.0.img.gz"
    printf 'osr' >"$tmp/out/$id/$id-1.0.0.os-release"
    printf 'pkgs' >"$tmp/out/$id/$id-1.0.0.packages.tsv"
    printf '{}' >"$tmp/out/$id/$id-1.0.0.cdx.json"
    printf 'aliases' >"$tmp/out/$id/$id-1.0.0.modules.alias.gz"
    printf 'not published' >"$tmp/out/$id/$id-1.0.0.ironflock.json"
    printf 'raw_size=1\nmin_disk_size=1\n' >"$tmp/out/$id/$id-1.0.0.sizes"
  done
  printf 'bundle' >"$tmp/out/ironflockos-amd64-efi-base/ironflockos-amd64-efi-base-1.0.0.raucb"
}

teardown() { rm -rf "$tmp"; }

@test "sums lists every published file of every image, by name" {
  run bash "$publish" sums "$tmp/out"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = 11 ]
  [[ "$output" == *"  ironflockos-amd64-efi-base-1.0.0.raucb"* ]]
  [[ "$output" == *"  ironflockos-amd64-efi-installer-1.0.0.cdx.json"* ]]
  # The hardware list, which the catalog names; the sizes are in the catalog.
  [[ "$output" == *"  ironflockos-amd64-efi-base-1.0.0.modules.alias.gz"* ]]
  [[ "$output" != *"ironflock.json"* ]]
  [[ "$output" != *".sizes"* ]]
  [[ "$output" != *"/"* ]]
}

@test "stage uploads each file and SHA256SUMS to staging/ironflockos/<version>/, uncached" {
  DRY_RUN=1 run bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^+ gcloud storage cp')" = 12 ]
  [[ "$output" == *"gs://ironflock-downloads/staging/ironflockos/1.0.0/ironflockos-amd64-efi-base-1.0.0.raucb"* ]]
  [[ "$output" == *"gs://ironflock-downloads/staging/ironflockos/1.0.0/SHA256SUMS"* ]]
  [[ "$output" == *"--cache-control=public, max-age=0"* ]]
  [[ "$output" != *"gs://ironflock-downloads/ironflockos/"* ]]
  [[ "$output" == *"dry run, nothing changed: would have staged 11 files"* ]]
}

@test "files lists each published file's sha256, size and name, as SHA256SUMS does" {
  run bash "$publish" files "$tmp/out"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = 11 ]
  [[ "$output" == *"$(printf 'bundle' | sha256sum | cut -d' ' -f1)"$'\t'6$'\t'ironflockos-amd64-efi-base-1.0.0.raucb* ]]
  [ "$(echo "$output" | awk -F'\t' '{ print $1 "  " $3 }')" = "$(bash "$publish" sums "$tmp/out")" ]
}

@test "stage uploads SHA256SUMS only after every file" {
  DRY_RUN=1 PUBLISH_JOBS=3 run bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  last=$(echo "$output" | grep '^+ gcloud storage cp' | tail -n 1)
  [[ "$last" == *"/1.0.0/SHA256SUMS" ]]
}

# fake_gcloud: gcloud that logs its calls to $tmp/log and fails every call
# whose arguments contain $FAIL (if set). storage ls lists $tmp/staged;
# objects describe finds a live object only when $tmp/live/<name> exists,
# and gives it the md5 "same" when that file says same, else "other"; a
# staged object's md5 is always "same".
fake_gcloud() {
  mkdir -p "$tmp/bin" "$tmp/live"
  cat >"$tmp/bin/gcloud" <<STANDIN
#!/bin/bash
echo "gcloud \$*" >>"$tmp/log"
if [ -n "\${FAIL:-}" ] && [[ "\$*" == *"\$FAIL"* ]]; then exit 1; fi
if [ "\$1 \$2" = "storage ls" ]; then cat "$tmp/staged"; exit 0; fi
if [ "\$1 \$2 \$3" = "storage objects describe" ]; then
  name=\${4##*/}
  case "\$4" in
    gs://ironflock-downloads/ironflockos/*)
      [ -f "$tmp/live/\$name" ] || exit 1
      if [ "\$(cat "$tmp/live/\$name")" = same ]; then md5=same; else md5=other; fi ;;
    *) md5=same ;;
  esac
  case "\$5" in
    *md5_hash*) echo "\$md5" ;;
    *size*) echo 5 ;;
    *) echo "\$name" ;;
  esac
fi
exit 0
STANDIN
  chmod +x "$tmp/bin/gcloud"
}

@test "stage: a failed upload fails it, after trying the rest, and SHA256SUMS is not staged" {
  fake_gcloud
  FAIL=amd64-efi-base-1.0.0.raucb run env PATH="$tmp/bin:$PATH" bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -ne 0 ]
  [ "$(grep -c 'storage cp' "$tmp/log")" = 11 ]
  ! grep -q '1.0.0/SHA256SUMS' "$tmp/log"
}

@test "stage: every file, then SHA256SUMS, through gcloud" {
  fake_gcloud
  run env PATH="$tmp/bin:$PATH" bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  [ "$(grep -c 'storage cp' "$tmp/log")" = 12 ]
  tail -n 1 "$tmp/log" | grep -q 'staging/ironflockos/1.0.0/SHA256SUMS$'
}

# staged N: N objects in the staging tree of 1.0.0.
staged() {
  for i in $(seq "$1"); do echo "gs://ironflock-downloads/staging/ironflockos/1.0.0/file$i"; done >"$tmp/staged"
}

@test "promote copies every staged object that is not live, and keeps a live one with the same bytes" {
  fake_gcloud
  staged 12
  echo same >"$tmp/live/file3"
  run env PATH="$tmp/bin:$PATH" bash "$publish" promote 1.0.0
  [ "$status" -eq 0 ]
  [ "$(grep -c 'storage cp' "$tmp/log")" = 11 ]
  ! grep -q 'storage cp .*/file3 ' "$tmp/log"
  [[ "$output" == *"promoted gs://ironflock-downloads/staging/ironflockos/1.0.0/ to gs://ironflock-downloads/ironflockos/1.0.0/"* ]]
}

@test "promote refuses a live object with other bytes, after trying the rest" {
  fake_gcloud
  staged 12
  echo other >"$tmp/live/file7"
  run env PATH="$tmp/bin:$PATH" bash "$publish" promote 1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"gs://ironflock-downloads/ironflockos/1.0.0/file7 is live with different bytes"* ]]
  ! grep -q 'storage cp .*/file7 ' "$tmp/log"
  [ "$(grep -c 'storage cp' "$tmp/log")" = 11 ]
  [[ "$output" != *"promoted"* ]]
}

@test "promote: a failed copy fails it" {
  fake_gcloud
  staged 12
  FAIL=staging/ironflockos/1.0.0/file9 run env PATH="$tmp/bin:$PATH" bash "$publish" promote 1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" != *"promoted"* ]]
}

@test "stage and promote make one gcloud call before the parallel ones; a dry run makes none" {
  fake_gcloud
  run env PATH="$tmp/bin:$PATH" bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$tmp/log")" = "gcloud auth print-access-token" ]
  [ "$(grep -c 'auth print-access-token' "$tmp/log")" = 1 ]
  rm "$tmp/log"
  staged 3
  run env PATH="$tmp/bin:$PATH" bash "$publish" promote 1.0.0
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$tmp/log")" = "gcloud auth print-access-token" ]
  DRY_RUN=1 run bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" != *"print-access-token"* ]]
}

@test "a failed first gcloud call is a warning: the uploads go on and tell" {
  fake_gcloud
  FAIL=print-access-token run env PATH="$tmp/bin:$PATH" bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: gcloud auth print-access-token failed"* ]]
  [ "$(grep -c 'storage cp' "$tmp/log")" = 12 ]
}

@test "PUBLISH_JOBS must be a number" {
  PUBLISH_JOBS=x DRY_RUN=1 run bash "$publish" stage "$tmp/out" 1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"PUBLISH_JOBS must be a number"* ]]
}

# fake_curl: curl that answers every HEAD with Content-Length 5, but 4 for
# a URL that contains $SHORT (if set), and writes $tmp/<last path part> for
# a download (-o).
fake_curl() {
  cat >"$tmp/bin/curl" <<STANDIN
#!/bin/bash
out="" url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift ;; http*) url=\$1 ;; esac; shift; done
if [ -n "\$out" ]; then cp "$tmp/\${url##*/}" "\$out"; exit 0; fi
if [ -n "\${SHORT:-}" ] && [[ "\$url" == *"\$SHORT"* ]]; then printf 'HTTP/2 200\r\ncontent-length: 4\r\n\r\n'; else printf 'HTTP/2 200\r\ncontent-length: 5\r\n\r\n'; fi
STANDIN
  chmod +x "$tmp/bin/curl"
}

@test "check: every file of SHA256SUMS answers through the proxy with the bucket's size; one that does not fails it" {
  fake_gcloud
  fake_curl
  for i in $(seq 12); do echo "$(printf '%064d' "$i")  file$i"; echo same >"$tmp/live/file$i"; done >"$tmp/SHA256SUMS"
  printf 'x\t1\t-\t-\t-\nacl\t1\thttps://example.org/acl.dsc\tSHA256:0\t-\n' >"$tmp/SOURCES"
  printf '{}' >"$tmp/manifest.json"
  # the bucket's copies of SHA256SUMS and SOURCES are the proxy's
  sed -i.bak 's|^exit 0$|if [ "$1 $2" = "storage cat" ]; then cat "'"$tmp"'/${3##*/}"; fi\nexit 0|' "$tmp/bin/gcloud"
  run env PATH="$tmp/bin:$PATH" bash "$publish" check 1.0.0 "$tmp/manifest.json"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'objects describe gs://ironflock-downloads/ironflockos/1.0.0/file' "$tmp/log")" = 12 ]
  [[ "$output" == *"every file of 1.0.0, its SOURCES and the catalog answer"* ]]
  SHORT=file11 run env PATH="$tmp/bin:$PATH" bash "$publish" check 1.0.0 "$tmp/manifest.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"file11 answers with 4 bytes, the bucket holds 5"* ]]
}

@test "meta: checksums, file list, SBOMs, source packages and the catalog's small files, no image or bundle" {
  for id in ironflockos-amd64-efi-base ironflockos-amd64-efi-installer; do
    printf 'src\t1\n' >"$tmp/out/$id/$id-1.0.0.sources.tsv"
  done
  printf 'ironflockos-amd64-efi-base\n' >"$tmp/out/ironflockos-amd64-efi-installer/ironflockos-amd64-efi-installer-1.0.0.payloads"
  run bash "$publish" meta "$tmp/out" "$tmp/meta"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/meta/SHA256SUMS")" = "$(bash "$publish" sums "$tmp/out")" ]
  [ "$(cat "$tmp/meta/files.tsv")" = "$(bash "$publish" files "$tmp/out")" ]
  [ -f "$tmp/meta/ironflockos-amd64-efi-base-1.0.0.cdx.json" ]
  [ "$(cat "$tmp/meta/sources.tsv")" = "$(printf 'src\t1')" ]
  [ -f "$tmp/meta/catalog/ironflockos-amd64-efi-base/ironflockos-amd64-efi-base-1.0.0.os-release" ]
  [ -f "$tmp/meta/catalog/ironflockos-amd64-efi-base/ironflockos-amd64-efi-base-1.0.0.sizes" ]
  [ -f "$tmp/meta/catalog/ironflockos-amd64-efi-installer/ironflockos-amd64-efi-installer-1.0.0.payloads" ]
  [ -z "$(find "$tmp/meta" -name '*.img.gz' -o -name '*.raucb')" ]
}

@test "meta: the catalog built from it is the catalog built from the files" {
  command -v go >/dev/null || skip "no go"
  for id in ironflockos-amd64-efi-base ironflockos-amd64-efi-installer; do
    printf 'src\t1\n' >"$tmp/out/$id/$id-1.0.0.sources.tsv"
    printf 'NAME="IronFlockOS"\nID=ironflockos\nIMAGE_ID=%s\nIMAGE_VERSION=1.0.0\nBUILD_ID=20261120T095512Z-g1a2b3c4\n' "$id" \
      >"$tmp/out/$id/$id-1.0.0.os-release"
  done
  printf 'ironflockos-amd64-efi-base\n' >"$tmp/out/ironflockos-amd64-efi-installer/ironflockos-amd64-efi-installer-1.0.0.payloads"
  bash "$publish" meta "$tmp/out" "$tmp/meta"
  build() {
    (cd "$repo/tools/catalog" && go run . build "$@" -repo ../.. -version 1.0.0 -channel test -url https://dl.example/ironflockos/1.0.0 \
      -min-agent 1.6.3 -boards ../../release/boards.json) | jq 'del(.issued_at)'
  }
  hashed=$(build -dir "$tmp/out")
  listed=$(build -dir "$tmp/meta/catalog" -files "$tmp/meta/files.tsv")
  [ -n "$hashed" ]
  [ "$hashed" = "$listed" ]
}

@test "stage refuses a directory without release files" {
  mkdir "$tmp/empty"
  DRY_RUN=1 run bash "$publish" stage "$tmp/empty" 1.0.0
  [ "$status" -ne 0 ]
}

@test "promote copies staging to the live tree; the catalog goes to ironflockos/manifest.json" {
  DRY_RUN=1 run bash "$publish" promote 1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"gs://ironflock-downloads/staging/ironflockos/1.0.0/* gs://ironflock-downloads/ironflockos/1.0.0/"* ]]
  printf '{}' >"$tmp/manifest.json"
  DRY_RUN=1 run bash "$publish" catalog "$tmp/manifest.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gs://ironflock-downloads/ironflockos/manifest.json"* ]]
}

@test "notes publishes release-notes/<x.y.z>.md as ironflockos/release-notes.json, uncached" {
  mkdir "$tmp/notes"
  printf '## New\n\n- A feature.\n' >"$tmp/notes/0.11.0.md"
  printf '## Fixed\n\n- A bug.\n' >"$tmp/notes/0.12.0.md"
  DRY_RUN=1 run bash "$publish" notes "$tmp/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ gcloud storage cp --quiet --cache-control=public, max-age=0 "*" gs://ironflock-downloads/ironflockos/release-notes.json"* ]]
  [[ "$output" == *"would have published the release notes of 2 version(s)"* ]]
}

@test "notes publishes {} without release notes, also when the directory is missing" {
  DRY_RUN=1 run bash "$publish" notes "$tmp/missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gs://ironflock-downloads/ironflockos/release-notes.json"* ]]
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
  [[ "$CATALOG_KMS_KEY" =~ ^projects/[a-z0-9-]+/locations/[a-z0-9-]+/keyRings/ironflock-release/cryptoKeys/ironflockos-catalog/cryptoKeyVersions/[0-9]+$ ]]
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
  ! echo "$output" | grep -v -E 'ironflockos-(release|publisher)@record-1283\.iam\.gserviceaccount\.com'
  # Every authentication step is guarded by the release mode, but in the
  # production job, which runs on a release tag only.
  run awk '/^  [a-z][a-z-]*:$/ { job = $1 } /uses: google-github-actions\/auth@/ && job != "production:" { print prev } { prev = $0 }' \
    "$repo/.github/workflows/release.yml"
  [ -n "$output" ]
  ! echo "$output" | grep -v "if: env.MODE == 'release'"
  grep -q "if: .*needs.verify.outputs.mode == 'tag' && inputs.promote-production" "$repo/.github/workflows/release.yml"
}

@test "release.yml: a run on a tag builds nothing" {
  for job in source build manifest sign e2e stage sources promote vm-images; do
    run awk -v job="  $job:" '$0 == job { f = 1; next } f && /^  [a-z][a-z-]*:$/ { exit } f && /^    if:/ { print; exit }' \
      "$repo/.github/workflows/release.yml"
    [[ "$output" == *"mode == 'release' || needs.verify.outputs.mode == 'dry-run'"* ]] || { echo "$job: $output"; return 1; }
  done
}
