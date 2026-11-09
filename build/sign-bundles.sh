#!/usr/bin/env bash
# The release signature of the RAUC bundles (ADR-0006, docs/signing.md; WP-1.6).
#   sign-bundles.sh release|dry-run DIR
#
# Runs in the build container (build/sign-in-builder.sh). DIR holds one
# directory per image as a release build leaves it (out/<image-id>/): the
# image, the bundle sealed with the build's throwaway key, and that key's CA
# (<name>.seal-ca.pem). Each bundle is checked against its sealing CA,
# re-signed (rauc resign, payload unchanged), checked the way the device
# checks it against the keyring that must accept it, and against the keyrings
# that must not; then the sealing CA goes and SHA256SUMS is rewritten.
#
# release  the bundle signer in Cloud KMS through Google's PKCS#11 library
#          (pinned in build/release.conf), as the workload identity that
#          release.yml's sign job authenticated (GOOGLE_APPLICATION_CREDENTIALS).
#          The bundles verify against the IronFlockOS root CA only.
# dry-run  a throwaway stand-in for the bundle signer: the same steps without
#          the release identity, for dry runs of release.yml and local checks.
#          The bundles verify against the stand-in only, never against the
#          IronFlockOS root CA.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

mode=${1:-}
dir=${2:-}
case "$mode" in
  release | dry-run) ;;
  *) die "usage: sign-bundles.sh release|dry-run DIR" ;;
esac
[ -d "$dir" ] || die "usage: sign-bundles.sh release|dry-run DIR ($dir is no directory)"
require rauc openssl sha256sum
load_conf "$here/release.conf"
root_ca=$src/pki/flockos-root-ca.pem
[ -f "$root_ca" ] || die "$root_ca is missing (WP-0.5: docs/signing.md)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"

case "$mode" in
  release)
    : "${GOOGLE_APPLICATION_CREDENTIALS:?release signing needs the workload identity (GOOGLE_APPLICATION_CREDENTIALS)}"
    require curl tar
    tarball=$work/libkmsp11.tar.gz
    curl -fsSL --proto '=https' --retry 5 --retry-all-errors -o "$tarball" \
      "https://github.com/GoogleCloudPlatform/kms-integrations/releases/download/pkcs11-v$KMSP11_VERSION/libkmsp11-$KMSP11_VERSION-linux-amd64.tar.gz"
    echo "$KMSP11_SHA256  $tarball" | sha256sum -c --quiet - ||
      die "libkmsp11 $KMSP11_VERSION is not the pinned tarball (build/release.conf)"
    tar -xzf "$tarball" -C "$work"
    lib=$work/libkmsp11-$KMSP11_VERSION-linux-amd64/libkmsp11.so
    openssl dgst -sha384 -verify "$here/keys/google-kmsp11-release.pub" -signature "$lib.sig" "$lib" >/dev/null ||
      die "libkmsp11 does not carry Google's release signature"
    printf 'tokens:\n  - key_ring: %s\n    label: %s\n' "$KMS_KEY_RING" "$KMS_TOKEN" >"$work/kmsp11.yaml"
    chmod 0600 "$work/kmsp11.yaml"
    export KMS_PKCS11_CONFIG=$work/kmsp11.yaml RAUC_PKCS11_MODULE=$lib
    key="pkcs11:token=$KMS_TOKEN;object=$KMS_KEY"
    # The newest bundle signer certificate (pki/README.md).
    cert=$(printf '%s\n' "$src"/pki/flockos-bundle-signer-*.pem | sort -V | tail -n 1)
    [ -f "$cert" ] || die "no bundle signer certificate in pki/"
    openssl x509 -in "$cert" -noout -checkend $((30 * 86400)) >/dev/null ||
      die "$(basename "$cert") expires within 30 days: issue the next one (docs/signing.md)"
    keyring=$root_ca
    ;;
  dry-run)
    throwaway_signer "$work/standin" "IronFlockOS release dry run"
    key=$work/standin/signer.key
    cert=$work/standin/signer.pem
    keyring=$work/standin/keyring.pem
    ;;
esac
openssl verify -purpose any -CAfile "$keyring" "$cert" >/dev/null ||
  die "$(basename "$cert") is not issued by the CA the bundles must chain to"
signer=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')

# check NAME KEYRING COMPATIBLE BUNDLE: verify as the device does (its
# system.conf: the keyring, code-signing purpose, the signing time).
check() {
  printf '[system]\ncompatible=%s\nbootloader=noop\n\n[keyring]\npath=%s\nuse-bundle-signing-time=true\ncheck-purpose=codesign\n' \
    "$3" "$2" >"$work/$1.conf"
  rauc --conf="$work/$1.conf" info "$4" >"$work/$1.info" 2>&1
}

n=0
for bundle in "$dir"/*/*.raucb; do
  [ -f "$bundle" ] || continue
  d=$(dirname "$bundle")
  id=$(basename "$d")
  name=$(basename "$bundle" .raucb)
  seal=$d/$name.seal-ca.pem
  [ -f "$seal" ] || die "$name.raucb has no sealing CA ($name.seal-ca.pem): not from a release build"
  # RAUC checks a bundle's payload only where nothing else can change the
  # file meanwhile: a copy of root's own, not the bind-mounted original.
  sealed=$work/sealed.raucb
  cp "$bundle" "$sealed"
  check sealed "$seal" "$id" "$sealed" || {
    cat "$work/sealed.info" >&2
    die "$name.raucb does not verify against its sealing CA"
  }
  signed=$work/signed.raucb
  rm -f "$signed"
  rauc --conf="$work/sealed.conf" resign --signing-keyring="$keyring" \
    --cert="$cert" --key="$key" "$sealed" "$signed" >"$work/resign.log" 2>&1 || {
    cat "$work/resign.log" >&2
    die "$name.raucb: rauc resign failed"
  }
  check final "$keyring" "$id" "$signed" || {
    cat "$work/final.info" >&2
    die "$name.raucb: the signed bundle does not verify"
  }
  grep -q "Compatible:.*'$id'" "$work/final.info" || die "$name.raucb is not compatible $id"
  if check reject-seal "$seal" "$id" "$signed"; then
    die "$name.raucb still verifies against its sealing CA"
  fi
  if [ "$mode" = dry-run ] && check reject-root "$root_ca" "$id" "$signed"; then
    die "$name.raucb, signed by the dry-run stand-in, verifies against the IronFlockOS root CA"
  fi
  cp "$signed" "$bundle"
  rm -f "$seal" "$signed" "$sealed"
  (cd "$d" && sha256sum -- *.img.gz *.raucb >SHA256SUMS)
  n=$((n + 1))
  log "$name.raucb: signed by $signer ($mode)"
done
[ "$n" -gt 0 ] || die "no bundles in $dir/*/"
chown -R "${FLOCKOS_HOST_UID:-0}:${FLOCKOS_HOST_GID:-0}" "$dir"
log "$n bundles signed; they verify against $(openssl x509 -in "$keyring" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
