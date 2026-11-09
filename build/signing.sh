#!/usr/bin/env bash
# Prepare the RAUC signing material of one build (ADR-0006, docs/signing.md).
#   signing.sh DIR
# Writes DIR/signing.env:
#   KEYRING         the CA the image trusts (/etc/rauc/keyring.pem)
#   KEY, CERT       what build/mkbundle.sh signs the bundle with
#   BUNDLE_KEYRING  what the bundle as built verifies against
#   SEALED          1 when the bundle still needs its release signature
#
# dev      a throwaway CA and signer, made here and never kept: images and
#          bundles of one build trust each other and nothing else, so a
#          pull-request image can never install a release bundle and a
#          release image never a pull-request bundle.
# release  the image trusts the IronFlockOS root CA (pki/flockos-root-ca.pem).
#          The build holds no release key: it seals the bundle with a
#          throwaway signer, and release.yml's sign job, the only job with the
#          Cloud KMS identity, re-signs it with the bundle signer
#          (build/sign-bundles.sh).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

dir=${1:?usage: signing.sh DIR}
mkdir -p "$dir"
chmod 0700 "$dir"

case "${FLOCKOS_SIGNING:-dev}" in
  dev)
    throwaway_signer "$dir" "IronFlockOS development"
    {
      echo "KEYRING=$dir/keyring.pem"
      echo "KEY=$dir/signer.key"
      echo "CERT=$dir/signer.pem"
      echo "BUNDLE_KEYRING=$dir/keyring.pem"
      echo "SEALED=0"
    } >"$dir/signing.env"
    log "throwaway CA and signer made (valid 30 days)"
    ;;
  release)
    ca=$src/pki/flockos-root-ca.pem
    [ -f "$ca" ] || die "release signing needs $ca (WP-0.5: docs/signing.md)"
    cp "$ca" "$dir/keyring.pem"
    throwaway_signer "$dir/seal" "IronFlockOS release sealing"
    {
      echo "KEYRING=$dir/keyring.pem"
      echo "KEY=$dir/seal/signer.key"
      echo "CERT=$dir/seal/signer.pem"
      echo "BUNDLE_KEYRING=$dir/seal/keyring.pem"
      echo "SEALED=1"
    } >"$dir/signing.env"
    log "release build: the image trusts the IronFlockOS root CA; the bundle is sealed for release.yml's sign job"
    ;;
  *) die "FLOCKOS_SIGNING must be dev or release" ;;
esac
