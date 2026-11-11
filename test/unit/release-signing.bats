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
    in_job && /- target:/ { flush(); t = $3; v = ""; k = "std" }
    in_job && /^ +variant:/ { v = $2 }
    in_job && /^ +kernel:/ { k = $2 }
    END { flush() }
  ' "$repo/.github/workflows/$1" | sort -u
}

@test "every image CI tests is one build.yml builds" {
  built=$(images build.yml image)
  [ "$(echo "$built" | wc -l)" -ge 6 ]
  tested=$(images ci.yml image-test)
  [ -n "$tested" ]
  missing=$(comm -13 <(echo "$built") <(echo "$tested"))
  [ -z "$missing" ] || { echo "ci.yml image-test uses images build.yml does not build: $missing"; return 1; }
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
  grep -q 'pattern: release-image-\*' "$wf/release.yml"
  ! grep -qE 'pattern: image-|name: image-' "$wf/release.yml"
  ! grep -A6 'uses: ./.github/workflows/build.yml' "$wf/ci.yml" | grep -q 'prefix:'
  # every artifact build.yml uploads or downloads carries the prefix
  ! grep -E '^\s+(name|pattern): image-' "$wf/build.yml"
  [ "$(grep -c 'name: ${{ inputs.prefix }}-' "$wf/build.yml")" -eq 2 ]
  [ "$(grep -c 'pattern: ${{ inputs.prefix }}-' "$wf/build.yml")" -eq 1 ]
}

@test "the assets job downloads the release's checksums and SBOMs, not its images" {
  wf=$repo/.github/workflows/release.yml
  assets=$(sed -n '/^  assets:/,/^  [a-z-]*:$/p' "$wf")
  [[ "$assets" == *"name: release-meta-release"* ]]
  [[ "$assets" != *"name: release-release"* ]]
  stage=$(sed -n '/^  stage:/,/^  promote:/p' "$wf")
  [[ "$stage" == *'name: release-meta-${{ env.MODE }}'* ]]
  [[ "$stage" == *"build/publish.sh sums out > meta/SHA256SUMS"* ]]
}
