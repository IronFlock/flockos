#!/usr/bin/env bats
# Release signing (WP-1.6, docs/signing.md): what a build signs with in each
# mode, the pins of the sign step, and the image list the workflows share.

repo="$BATS_TEST_DIRNAME/../.."

setup() {
  tmp=$(mktemp -d)
}

teardown() { rm -rf "$tmp"; }

env_of() { sed -n "s/^$1=//p" "$tmp/pki/signing.env"; }

@test "a dev build trusts and signs with one throwaway CA of its own" {
  IRONFLOCKOS_SIGNING=dev run bash "$repo/build/signing.sh" "$tmp/pki"
  [ "$status" -eq 0 ]
  [ "$(env_of KEYRING)" = "$(env_of BUNDLE_KEYRING)" ]
  [ "$(env_of SEALED)" = 0 ]
  openssl verify -purpose any -CAfile "$(env_of KEYRING)" "$(env_of CERT)"
  openssl x509 -in "$(env_of CERT)" -noout -ext extendedKeyUsage | grep -q 'Code Signing'
  ! cmp -s "$(env_of KEYRING)" "$repo/pki/ironflockos-root-ca.pem"
}

@test "a release build trusts the IronFlockOS root CA and seals with a throwaway key" {
  IRONFLOCKOS_SIGNING=release run bash "$repo/build/signing.sh" "$tmp/pki"
  [ "$status" -eq 0 ]
  cmp "$(env_of KEYRING)" "$repo/pki/ironflockos-root-ca.pem"
  [ "$(env_of SEALED)" = 1 ]
  [ "$(env_of BUNDLE_KEYRING)" != "$(env_of KEYRING)" ]
  openssl verify -purpose any -CAfile "$(env_of BUNDLE_KEYRING)" "$(env_of CERT)"
  # The sealing key is no release key: nothing it signs chains to the root CA.
  ! openssl verify -purpose any -CAfile "$repo/pki/ironflockos-root-ca.pem" "$(env_of CERT)" 2>/dev/null
  # The build gets no KMS key: KEY is a file, not a pkcs11: URI.
  [ -f "$(env_of KEY)" ]
}

@test "two release builds seal with different keys" {
  IRONFLOCKOS_SIGNING=release bash "$repo/build/signing.sh" "$tmp/a"
  IRONFLOCKOS_SIGNING=release bash "$repo/build/signing.sh" "$tmp/b"
  ! cmp -s "$tmp/a/seal/keyring.pem" "$tmp/b/seal/keyring.pem"
}

@test "signing.sh refuses an unknown mode" {
  IRONFLOCKOS_SIGNING=kms run bash "$repo/build/signing.sh" "$tmp/pki"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev or release"* ]]
}

@test "sign-bundles.sh needs a mode and a directory" {
  run bash "$repo/build/sign-bundles.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"usage"* ]]
  run bash "$repo/build/sign-bundles.sh" kms "$tmp"
  [ "$status" -ne 0 ] && [[ "$output" == *"usage"* ]]
  run bash "$repo/build/sign-bundles.sh" dry-run "$tmp/missing"
  [ "$status" -ne 0 ] && [[ "$output" == *"no directory"* ]]
}

@test "the sign step's pins are complete" {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/build/release.conf"
  [[ "$KMSP11_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]
  [[ "$KMSP11_SHA256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$KMS_KEY_RING" =~ ^projects/[a-z0-9-]+/locations/[a-z0-9-]+/keyRings/[a-z0-9-]+$ ]]
  [ "${KMS_KEY_RING##*/}" = "$KMS_TOKEN" ]
  [ -n "$KMS_KEY" ]
  # Google's release key: ECDSA P-384, as the library's .sig needs.
  openssl pkey -pubin -in "$repo/build/keys/google-kmsp11-release.pub" -noout -text | grep -q 'NIST CURVE: P-384'
}

@test "the newest bundle signer certificate chains to the root CA" {
  cert=$(printf '%s\n' "$repo"/pki/ironflockos-bundle-signer-*.pem | sort -V | tail -n 1)
  [ -f "$cert" ]
  openssl verify -purpose any -CAfile "$repo/pki/ironflockos-root-ca.pem" "$cert"
  openssl x509 -in "$cert" -noout -ext extendedKeyUsage | grep -q 'Code Signing'
}

# images WORKFLOW JOB: the "target variant kernel" lines of a job's matrix
# (no kernel key: std).
images() {
  awk -v job="  $2:" '
    function flush() { if (t != "") print t, v, k; t = "" }
    $0 == job { in_job = 1; next }
    in_job && /^  [a-z][a-z-]*:$/ { exit }
    # the matrix only, not the inputs a reusable workflow gets from it
    in_job && /^    (uses|with):/ { exit }
    in_job && /- target:/ { flush(); t = $3; v = ""; k = "std" }
    in_job && /^ +variant:/ { v = $2 }
    in_job && /^ +kernel:/ { k = $2 }
    END { flush() }
  ' "$repo/.github/workflows/$1" | sort -u
}

# ci_jobs PREFIX: the "job target variant kernel" of ci.yml's jobs named
# PREFIX-*, from their one-line `with:` (no kernel: std).
ci_jobs() {
  awk -v prefix="  $1-" '
    /^  [a-z][a-z0-9-]*:$/ { job = substr($1, 1, length($1) - 1); in_job = (index($0, prefix) == 1); next }
    in_job && /^    with: \{/ {
      t = v = ""; k = "std"
      n = split($0, kv, /[{},] */)
      for (i = 1; i <= n; i++) {
        split(kv[i], p, /: */)
        gsub(/^ +| +$/, "", p[1])
        if (p[1] == "target") t = p[2]
        if (p[1] == "variant") v = p[2]
        if (p[1] == "kernel") k = p[2]
      }
      print job, t, v, k
    }
  ' "$repo/.github/workflows/ci.yml" | sort -u
}

@test "ci.yml builds exactly the images build.yml builds, one job each" {
  built=$(images build.yml image)
  [ "$(echo "$built" | wc -l)" -ge 6 ]
  [ "$(ci_jobs image | cut -d' ' -f2- | sort -u)" = "$built" ]
  # each job is named after its image
  ci_jobs image | while read -r job t v k; do
    suffix=""
    if [ "$k" = rt ]; then suffix=-rt; fi
    [ "$job" = "image-$t-$v$suffix" ] || { echo "$job builds $t $v $k"; return 1; }
  done
}

@test "every image CI tests is one build.yml builds, and its test needs only that image's job" {
  built=$(images build.yml image)
  tested=$(ci_jobs test)
  [ "$(echo "$tested" | wc -l)" -ge 5 ]
  echo "$tested" | while read -r job t v k; do
    suffix=""
    if [ "$k" = rt ]; then suffix=-rt; fi
    image=$t-$v$suffix
    [ "$job" = "test-$image" ] || { echo "$job tests $image"; return 1; }
    echo "$built" | grep -qx "$t $v $k" || { echo "$job: build.yml does not build $t $v $k"; return 1; }
    needs=$(awk -v job="  $job:" '$0 == job { f = 1; next } f && /^  [a-z]/ { exit } f && /^    needs:/ { print; exit }' "$repo/.github/workflows/ci.yml")
    [ "$needs" = "    needs: [image-$image]" ] || { echo "$job: $needs"; return 1; }
  done
}

@test "ci-ok needs every job of ci.yml but the switched-off Jetson jobs" {
  wf=$repo/.github/workflows/ci.yml
  jobs=$(awk '/^jobs:/ { f = 1; next } f && /^  [a-z][a-z0-9-]*:$/ { sub(/:$/, "", $1); print $1 }' "$wf" | grep -vxE 'ci-ok|jetson-rootfs|jetson-flash' | sort)
  needs=$(awk '$0 == "  ci-ok:" { f = 1; next } f && /^    needs:/ { n = 1; next } n && /^      - / { print $2; next } n { exit }' "$wf" | sort)
  [ -n "$jobs" ]
  [ "$jobs" = "$needs" ]
}

@test "RELEASE_IMAGES are the images build.yml builds and its installer sticks" {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/build/release.conf"
  built=$(images build.yml image | while read -r t v k; do
    if [ "$k" = rt ]; then echo "$t-$v-rt"; else echo "$t-$v"; fi
  done)
  sticks=$(awk '$0 == "  installer:" { f = 1; next } f && /^  [a-z]/ { exit } f && /- target:/ { print $3 "-installer" }' \
    "$repo/.github/workflows/build.yml")
  [ -n "$sticks" ]
  # shellcheck disable=SC2086 # a space-separated list
  [ "$(printf '%s\n' $RELEASE_IMAGES | sort)" = "$(printf '%s\n' $built $sticks | sort)" ]
}

@test "security.yml scans exactly the images build.yml builds" {
  # The "args" of the harness's rootfs-matrix: just rootfs TARGET VARIANT KERNEL.
  scanned=$(grep -o '"args": "[^"]*"' "$repo/.github/workflows/security.yml" | sed 's/^"args": "//; s/"$//' | sort -u)
  [ -n "$scanned" ]
  [ "$scanned" = "$(images build.yml image)" ]
}

@test "each rootfs-matrix entry names the tree just rootfs leaves" {
  # path is ironflockos-<name>/rootfs (build.sh: ROOTFS_WORK/<image-id>/rootfs).
  run python3 -I -c '
import json, re, sys
text = open(sys.argv[1]).read()
block = re.search(r"rootfs-matrix: >-\n((?:        .*\n)+)", text).group(1)
entries = json.loads(" ".join(block.split()))
for e in entries:
    t, v, k = e["args"].split()
    image = t + "-" + v + ("-rt" if k == "rt" else "")
    assert e["name"] == image, e
    assert e["path"] == "ironflockos-" + image + "/rootfs", e
    assert e.get("runner", "ubuntu-latest") == ("ubuntu-latest" if t == "amd64-efi" else "ubuntu-24.04-arm"), e
print(len(entries))
' "$repo/.github/workflows/security.yml"
  [ "$status" -eq 0 ]
  [ "$output" = 6 ]
}

@test "release.yml's build names its artifacts apart from ci.yml's (a release pull request runs both in one run)" {
  wf=$repo/.github/workflows
  grep -A6 'uses: ./.github/workflows/build.yml' "$wf/release.yml" | grep -qx '      prefix: release-image'
  ! grep -qE 'pattern: image-|name: image-' "$wf/release.yml"
  ! grep -E 'prefix:' "$wf/ci.yml"
  # every artifact image.yml and installer.yml upload or download carries the prefix
  ! grep -E '^\s+(name|pattern): image-' "$wf/build.yml" "$wf/image.yml" "$wf/installer.yml"
  [ "$(grep -c 'name: ${{ inputs.prefix }}-' "$wf/image.yml")" -eq 1 ]
  [ "$(grep -c 'name: ${{ inputs.prefix }}-' "$wf/installer.yml")" -eq 1 ]
  [ "$(grep -c 'pattern: ${{ inputs.prefix }}-' "$wf/installer.yml")" -eq 1 ]
  [ "$(grep -c 'prefix: ${{ inputs.prefix }}' "$wf/build.yml")" -eq 2 ]
}

@test "the assets job downloads the release's checksums and SBOMs, not its images" {
  wf=$repo/.github/workflows/release.yml
  assets=$(sed -n '/^  assets:/,/^  [a-z-]*:$/p' "$wf")
  [[ "$assets" == *"name: release-meta-release"* ]]
  [[ "$assets" != *"name: release-release"* ]]
  stage=$(sed -n '/^  stage:/,/^  promote:/p' "$wf")
  [[ "$stage" == *'name: release-meta-${{ env.MODE }}'* ]]
  [[ "$stage" == *"build/publish.sh meta out meta"* ]]
}

@test "each job of release.yml downloads only what it needs" {
  wf=$repo/.github/workflows/release.yml
  # job JOB: the lines of a job.
  job() { awk -v job="  $1:" '$0 == job { f = 1; print; next } f && /^  [a-z][a-z-]*:$/ { exit } f' "$wf"; }
  # The whole release in one artifact is gone.
  ! grep -qE 'name: release-(release|dry-run|\$\{\{ env.MODE \}\})$' "$wf"
  # sign: its own image as built; attest, e2e, vm-images: one image as signed
  [[ "$(job sign)" == *'name: release-image-${{ matrix.image }}'* ]]
  [[ "$(job attest)" == *'-${{ matrix.image }}'* ]]
  [[ "$(job e2e)" == *'name: signed-${{ env.MODE }}-amd64-efi-base'* ]]
  [[ "$(job vm-images)" == *'name: signed-${{ env.MODE }}-${{ matrix.image }}'* ]]
  # stage: every image once; promote: only the hashes, sizes and small files
  [[ "$(job stage)" == *'pattern: signed-${{ env.MODE }}-*'* ]]
  [ "$(job promote | grep -c 'download-artifact@')" = 1 ]
  [[ "$(job promote)" == *'name: release-meta-${{ env.MODE }}'* ]]
  [[ "$(job promote)" == *'-files ../../meta/files.tsv'* ]]
}

@test "ci.yml grants the dry run every permission a job of release.yml asks for" {
  wf=$repo/.github/workflows
  # the scope: level lines of every job's permissions in release.yml
  asked=$(awk '/^    permissions:$/ { p = 1; next } p && /^      [a-z-]+: (read|write)$/ { print $1, $2; next } { p = 0 }' "$wf/release.yml" | sort -u)
  granted=$(awk '$0 == "  release-build:" { f = 1; next } f && /^  [a-z]/ { exit } f && /^    permissions:$/ { p = 1; next } p && /^      [a-z-]+: (read|write)$/ { print $1, $2; next } { p = 0 }' "$wf/ci.yml")
  [ -n "$asked" ] && [ -n "$granted" ]
  echo "$asked" | while read -r scope level; do
    g=$(echo "$granted" | awk -v s="$scope" '$1 == s { print $2 }')
    [ "$g" = write ] || [ "$g" = "$level" ] || { echo "release.yml asks for $scope $level, ci.yml grants ${g:-nothing}"; return 1; }
  done
}
