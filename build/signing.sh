#!/usr/bin/env bash
# Prepare the RAUC signing material of one build (ADR-0006).
#   signing.sh DIR
# Writes DIR/keyring.pem (the CA the image trusts), DIR/signer.pem and
# DIR/signing.env (KEY= a key file or a pkcs11: URI, CERT=, KEYRING=).
#
# dev      a throwaway CA and signer, made here and never kept: images and
#          bundles of one build trust each other and nothing else, so a
#          pull-request image can never install a release bundle and a
#          release image never a pull-request bundle.
# release  the FlockOS root CA (pki/flockos-root-ca.pem) and the bundle
#          signer whose key stays in Cloud KMS; the bundle is signed through
#          PKCS#11 (docs/signing.md). Wired up by WP-1.6.
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
    require openssl
    days=30
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days "$days" \
      -keyout "$dir/ca.key" -out "$dir/keyring.pem" \
      -subj "/O=IronFlock/CN=FlockOS development CA (throwaway)" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" 2>/dev/null
    openssl req -newkey rsa:3072 -nodes -sha256 \
      -keyout "$dir/signer.key" -out "$dir/signer.csr" \
      -subj "/O=IronFlock/CN=FlockOS development bundle signer (throwaway)" 2>/dev/null
    printf '%s\n' \
      "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature" \
      "extendedKeyUsage=critical,codeSigning" \
      "subjectKeyIdentifier=hash" \
      "authorityKeyIdentifier=keyid" >"$dir/signer.ext"
    openssl x509 -req -sha256 -days "$days" -in "$dir/signer.csr" \
      -CA "$dir/keyring.pem" -CAkey "$dir/ca.key" -CAcreateserial \
      -extfile "$dir/signer.ext" -out "$dir/signer.pem" 2>/dev/null
    rm -f "$dir/ca.key" "$dir/signer.csr" "$dir/signer.ext" "$dir/keyring.srl"
    openssl verify -purpose any -CAfile "$dir/keyring.pem" "$dir/signer.pem" >/dev/null
    {
      echo "KEY=$dir/signer.key"
      echo "CERT=$dir/signer.pem"
      echo "KEYRING=$dir/keyring.pem"
    } >"$dir/signing.env"
    log "throwaway CA and signer made (valid $days days)"
    ;;
  release)
    ca=$src/pki/flockos-root-ca.pem
    [ -f "$ca" ] || die "release signing needs $ca (WP-0.5: docs/signing.md)"
    : "${FLOCKOS_SIGNER_CERT:?release signing needs FLOCKOS_SIGNER_CERT (WP-1.6)}"
    : "${FLOCKOS_SIGNER_KEY:?release signing needs FLOCKOS_SIGNER_KEY, a pkcs11: URI (WP-1.6)}"
    cp "$ca" "$dir/keyring.pem"
    cp "$FLOCKOS_SIGNER_CERT" "$dir/signer.pem"
    {
      echo "KEY=$FLOCKOS_SIGNER_KEY"
      echo "CERT=$dir/signer.pem"
      echo "KEYRING=$dir/keyring.pem"
    } >"$dir/signing.env"
    ;;
  *) die "FLOCKOS_SIGNING must be dev or release" ;;
esac
