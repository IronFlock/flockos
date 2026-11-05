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
  FLOCKOS_SIGNING=dev run bash "$repo/build/signing.sh" "$tmp/pki"
  [ "$status" -eq 0 ]
  [ "$(env_of KEYRING)" = "$(env_of BUNDLE_KEYRING)" ]
  [ "$(env_of SEALED)" = 0 ]
  openssl verify -purpose any -CAfile "$(env_of KEYRING)" "$(env_of CERT)"
  openssl x509 -in "$(env_of CERT)" -noout -ext extendedKeyUsage | grep -q 'Code Signing'
  ! cmp -s "$(env_of KEYRING)" "$repo/pki/flockos-root-ca.pem"
}

@test "a release build trusts the FlockOS root CA and seals with a throwaway key" {
  FLOCKOS_SIGNING=release run bash "$repo/build/signing.sh" "$tmp/pki"
  [ "$status" -eq 0 ]
  cmp "$(env_of KEYRING)" "$repo/pki/flockos-root-ca.pem"
  [ "$(env_of SEALED)" = 1 ]
  [ "$(env_of BUNDLE_KEYRING)" != "$(env_of KEYRING)" ]
  openssl verify -purpose any -CAfile "$(env_of BUNDLE_KEYRING)" "$(env_of CERT)"
  # The sealing key is no release key: nothing it signs chains to the root CA.
  ! openssl verify -purpose any -CAfile "$repo/pki/flockos-root-ca.pem" "$(env_of CERT)" 2>/dev/null
  # The build gets no KMS key: KEY is a file, not a pkcs11: URI.
  [ -f "$(env_of KEY)" ]
}

@test "two release builds seal with different keys" {
  FLOCKOS_SIGNING=release bash "$repo/build/signing.sh" "$tmp/a"
  FLOCKOS_SIGNING=release bash "$repo/build/signing.sh" "$tmp/b"
  ! cmp -s "$tmp/a/seal/keyring.pem" "$tmp/b/seal/keyring.pem"
}

@test "signing.sh refuses an unknown mode" {
  FLOCKOS_SIGNING=kms run bash "$repo/build/signing.sh" "$tmp/pki"
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
  cert=$(printf '%s\n' "$repo"/pki/flockos-bundle-signer-*.pem | sort -V | tail -n 1)
  [ -f "$cert" ]
  openssl verify -purpose any -CAfile "$repo/pki/flockos-root-ca.pem" "$cert"
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
  [ "$(images security.yml rootfs)" = "$(images build.yml image)" ]
}
