#!/usr/bin/env bash
# One-time setup of the FlockOS RAUC PKI in Cloud KMS (ADR-0006,
# docs/signing.md). Run by a project owner from a checkout of IronFlock/flockos
# on a branch; it writes the two certificates into pki/ for a pull request.
#
#   tools/rauc-pki/ceremony.sh            show what would be done
#   tools/rauc-pki/ceremony.sh --yes      do it
#
# Creates (idempotent: what exists is kept):
#   key ring flockos-rauc-ca, key root           HSM, RSA_SIGN_PKCS1_4096_SHA256
#   key ring flockos-rauc,    key bundle-signer  HSM, RSA_SIGN_PKCS1_4096_SHA256
#   service account flockos-release, allowed to sign with bundle-signer only,
#     usable only by IronFlock/flockos release runs (workload identity
#     attribute release=<repo id>:release, as device-init's signer)
# then issues the root CA certificate (20 years) and the signer certificate
# (3 years) with rauc-pki, and disables the CA key version: it is enabled
# again only to issue the next signer certificate.
#
# Needs gcloud (authenticated, with Application Default Credentials: gcloud
# auth application-default login), go and openssl.
set -euo pipefail

PROJECT=${PROJECT:-record-1283}
LOCATION=${LOCATION:-europe-west1}
CA_RING=flockos-rauc-ca
CA_KEY=root
SIGNER_RING=flockos-rauc
SIGNER_KEY=bundle-signer
SA=flockos-release
REPO=IronFlock/flockos
POOL_PROVIDER_PROJECT_NUMBER=${POOL_PROVIDER_PROJECT_NUMBER:-615643915869}
POOL=github-pool
YEAR=$(date -u +%Y)
CA_PEM=pki/flockos-root-ca.pem
SIGNER_PEM=pki/flockos-bundle-signer-$YEAR.pem

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo"
yes=0
[ "${1:-}" = --yes ] && yes=1
gcloud=${GCLOUD:-gcloud}
command -v "$gcloud" >/dev/null || gcloud=$HOME/google-cloud-sdk/bin/gcloud

do_() {
  printf '+ %s\n' "$*"
  if [ "$yes" = 1 ]; then "$@"; fi
}
exists() { "$gcloud" "$@" >/dev/null 2>&1; }

kms=(--project "$PROJECT" --location "$LOCATION")
sa_email=$SA@$PROJECT.iam.gserviceaccount.com
repo_id=$(gh api "repos/$REPO" -q .id)
principal="principalSet://iam.googleapis.com/projects/$POOL_PROVIDER_PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/attribute.release/$repo_id:release"
ca_version="projects/$PROJECT/locations/$LOCATION/keyRings/$CA_RING/cryptoKeys/$CA_KEY/cryptoKeyVersions/1"
signer_version="projects/$PROJECT/locations/$LOCATION/keyRings/$SIGNER_RING/cryptoKeys/$SIGNER_KEY/cryptoKeyVersions/1"

echo "== key rings and HSM keys"
for ring in "$CA_RING" "$SIGNER_RING"; do
  exists kms keyrings describe "$ring" "${kms[@]}" || do_ "$gcloud" kms keyrings create "$ring" "${kms[@]}"
done
exists kms keys describe "$CA_KEY" --keyring "$CA_RING" "${kms[@]}" ||
  do_ "$gcloud" kms keys create "$CA_KEY" --keyring "$CA_RING" "${kms[@]}" \
    --purpose asymmetric-signing --default-algorithm rsa-sign-pkcs1-4096-sha256 --protection-level hsm \
    --labels product=flockos,use=rauc-root-ca
exists kms keys describe "$SIGNER_KEY" --keyring "$SIGNER_RING" "${kms[@]}" ||
  do_ "$gcloud" kms keys create "$SIGNER_KEY" --keyring "$SIGNER_RING" "${kms[@]}" \
    --purpose asymmetric-signing --default-algorithm rsa-sign-pkcs1-4096-sha256 --protection-level hsm \
    --labels product=flockos,use=rauc-bundle-signing

echo "== the release identity"
exists iam service-accounts describe "$sa_email" --project "$PROJECT" ||
  do_ "$gcloud" iam service-accounts create "$SA" --project "$PROJECT" \
    --display-name "FlockOS release" --description "Signs FlockOS RAUC bundles from IronFlock/flockos release runs"
# Sign and read the public key of bundle-signer; list the keys of its ring
# (the PKCS#11 library enumerates the ring). Nothing on the CA ring.
do_ "$gcloud" kms keys add-iam-policy-binding "$SIGNER_KEY" --keyring "$SIGNER_RING" "${kms[@]}" \
  --member "serviceAccount:$sa_email" --role roles/cloudkms.signerVerifier --condition=None
do_ "$gcloud" kms keyrings add-iam-policy-binding "$SIGNER_RING" "${kms[@]}" \
  --member "serviceAccount:$sa_email" --role roles/cloudkms.viewer --condition=None
do_ "$gcloud" iam service-accounts add-iam-policy-binding "$sa_email" --project "$PROJECT" \
  --member "$principal" --role roles/iam.workloadIdentityUser --condition=None

echo "== certificates"
if [ "$yes" = 1 ]; then
  state=$("$gcloud" kms keys versions describe 1 --key "$CA_KEY" --keyring "$CA_RING" "${kms[@]}" --format='value(state)')
  if [ "$state" = PENDING_GENERATION ]; then
    echo "waiting for the HSM to generate the CA key"
    until [ "$("$gcloud" kms keys versions describe 1 --key "$CA_KEY" --keyring "$CA_RING" "${kms[@]}" --format='value(state)')" = ENABLED ]; do sleep 5; done
  fi
fi
if [ ! -f "$CA_PEM" ]; then
  do_ go -C tools/rauc-pki run . ca -ca-key "$ca_version" -cn "FlockOS root CA" -years 20 -out "$repo/$CA_PEM"
fi
if [ ! -f "$SIGNER_PEM" ]; then
  do_ go -C tools/rauc-pki run . issue -ca-key "$ca_version" -ca-cert "$repo/$CA_PEM" \
    -key "$signer_version" -cn "FlockOS bundle signer $YEAR" -years 3 -out "$repo/$SIGNER_PEM"
fi
do_ "$gcloud" kms keys versions disable 1 --key "$CA_KEY" --keyring "$CA_RING" "${kms[@]}"

if [ "$yes" = 1 ]; then
  echo "== check"
  openssl verify -CAfile "$CA_PEM" "$SIGNER_PEM"
  for f in "$CA_PEM" "$SIGNER_PEM"; do
    openssl x509 -in "$f" -noout -subject -enddate -fingerprint -sha256
  done
  echo
  echo "Done. Commit $CA_PEM and $SIGNER_PEM on a branch and open a pull request."
else
  echo
  echo "Nothing was changed. Run again with --yes to do the steps above."
fi
