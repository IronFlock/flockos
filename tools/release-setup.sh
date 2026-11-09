#!/usr/bin/env bash
# One-time setup of FlockOS release publishing (WP-2.6, docs/release.md).
# Run by a project owner from a checkout of IronFlock/ironflockos on a branch,
# after the RAUC ceremony (tools/rauc-pki/ceremony.sh); it writes the catalog
# key's public key into pki/ for a pull request.
#
#   tools/release-setup.sh            show what would be done
#   tools/release-setup.sh --yes      do it
#
# Creates (idempotent: what exists is kept):
#   key ironflock-release/flockos-catalog  EC_SIGN_ED25519, SOFTWARE (as the
#     agent's agent-update key): signs dl/flockos/manifest.json (ADR-0009);
#     flockos-release (the ceremony's release identity) may sign with it and
#     with nothing else of that ring
#   service account flockos-publisher, usable only by IronFlock/ironflockos
#     release runs (workload identity attribute release=<repo id>:release):
#     object admin on gs://ironflock-downloads/staging/flockos/ and
#     gs://ironflock-downloads/flockos/ only (an IAM condition), object
#     viewer on the bucket for listing (its objects are public anyway), as
#     device-init's publisher; and the custom role flockosVmImagePublisher on
#     the project for images named flockos-* only (an IAM condition): it makes
#     the Compute Engine images of the releases (ADR-0010) and nothing else of
#     Compute Engine
# then writes pki/flockos-catalog.pub and prints the line for the agent's
# FLOCKOS_CATALOG_PUBLIC_KEYS (device-agent src/osupdate/catalog.go).
#
# Needs gcloud (authenticated as a project owner), gh and openssl.
set -euo pipefail
PROJECT=${PROJECT:-record-1283}
LOCATION=${LOCATION:-europe-west1}
RING=ironflock-release
KEY=flockos-catalog
SIGNER=flockos-release
PUBLISHER=flockos-publisher
IMAGE_ROLE=flockosVmImagePublisher
BUCKET=ironflock-downloads
REPO=IronFlock/ironflockos
POOL_PROVIDER_PROJECT_NUMBER=${POOL_PROVIDER_PROJECT_NUMBER:-615643915869}
POOL=github-pool
PUB=pki/flockos-catalog.pub
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
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
# bind_ COMMAND...: an IAM binding. A service account created a moment ago
# can be unknown to IAM for a minute ("does not exist"), so it is retried.
bind_() {
  printf '+ %s\n' "$*"
  [ "$yes" = 1 ] || return 0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    "$@" && return 0
    [ "$i" = 12 ] && return 1
    echo "retrying in 10 s: IAM may not know the new service account yet"
    sleep 10
  done
}

kms=(--project "$PROJECT" --location "$LOCATION")
signer_email=$SIGNER@$PROJECT.iam.gserviceaccount.com
publisher_email=$PUBLISHER@$PROJECT.iam.gserviceaccount.com
repo_id=$(gh api "repos/$REPO" -q .id)
principal="principalSet://iam.googleapis.com/projects/$POOL_PROVIDER_PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/attribute.release/$repo_id:release"

if ! exists iam service-accounts describe "$signer_email" --project "$PROJECT"; then
  echo "$signer_email does not exist: run tools/rauc-pki/ceremony.sh first" >&2
  exit 1
fi

echo "== the catalog key"
exists kms keys describe "$KEY" --keyring "$RING" "${kms[@]}" ||
  do_ "$gcloud" kms keys create "$KEY" --keyring "$RING" "${kms[@]}" \
    --purpose asymmetric-signing --default-algorithm ec-sign-ed25519 --protection-level software \
    --labels product=flockos,use=catalog-signing
bind_ "$gcloud" kms keys add-iam-policy-binding "$KEY" --keyring "$RING" "${kms[@]}" \
  --member "serviceAccount:$signer_email" --role roles/cloudkms.signerVerifier --condition=None

echo "== the publisher"
exists iam service-accounts describe "$publisher_email" --project "$PROJECT" ||
  do_ "$gcloud" iam service-accounts create "$PUBLISHER" --project "$PROJECT" \
    --display-name "FlockOS publisher" --description "Publishes FlockOS releases from IronFlock/ironflockos release runs"
condition=$(mktemp)
images_condition=$(mktemp)
trap 'rm -f "$condition" "$images_condition"' EXIT
cat >"$condition" <<CONDITION
title: flockos trees
description: the FlockOS staging and live trees only
expression: >-
  resource.name.startsWith("projects/_/buckets/$BUCKET/objects/staging/flockos/") ||
  resource.name.startsWith("projects/_/buckets/$BUCKET/objects/flockos/")
CONDITION
bind_ "$gcloud" storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$publisher_email" --role roles/storage.objectAdmin --condition-from-file "$condition"
bind_ "$gcloud" storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$publisher_email" --role roles/storage.objectViewer --condition=None
bind_ "$gcloud" iam service-accounts add-iam-policy-binding "$publisher_email" --project "$PROJECT" \
  --member "$principal" --role roles/iam.workloadIdentityUser --condition=None

echo "== the Compute Engine images of the releases (ADR-0010)"
exists iam roles describe "$IMAGE_ROLE" --project "$PROJECT" ||
  do_ "$gcloud" iam roles create "$IMAGE_ROLE" --project "$PROJECT" --stage GA \
    --title "FlockOS VM image publisher" \
    --description "Makes the Compute Engine images of FlockOS releases; bound for flockos-* images only" \
    --permissions compute.images.create,compute.images.get,compute.images.setLabels,compute.globalOperations.get
cat >"$images_condition" <<CONDITION
title: flockos images
description: Compute Engine images named flockos-* only
expression: >-
  resource.type != "compute.googleapis.com/Image" ||
  resource.name.startsWith("projects/$PROJECT/global/images/flockos-")
CONDITION
bind_ "$gcloud" projects add-iam-policy-binding "$PROJECT" --format none \
  --member "serviceAccount:$publisher_email" --role "projects/$PROJECT/roles/$IMAGE_ROLE" \
  --condition-from-file "$images_condition"

echo "== the catalog key's public key"
if [ "$yes" = 1 ]; then
  state=$("$gcloud" kms keys versions describe 1 --key "$KEY" --keyring "$RING" "${kms[@]}" --format='value(state)')
  until [ "$state" = ENABLED ]; do
    echo "waiting for KMS to generate the key ($state)"
    sleep 5
    state=$("$gcloud" kms keys versions describe 1 --key "$KEY" --keyring "$RING" "${kms[@]}" --format='value(state)')
  done
  "$gcloud" kms keys versions get-public-key 1 --key "$KEY" --keyring "$RING" "${kms[@]}" --output-file "$PUB"
  raw=$(openssl pkey -pubin -in "$PUB" -outform DER | tail -c 32 | base64)
  echo
  echo "Done. Commit $PUB on a branch and open a pull request."
  echo "The device-agent trusts the catalog with this line in FLOCKOS_CATALOG_PUBLIC_KEYS"
  echo "(src/osupdate/catalog.go):"
  echo
  echo "$raw # Cloud KMS $RING/$KEY version 1, FlockOS release catalog"
else
  echo "+ $gcloud kms keys versions get-public-key 1 --key $KEY --keyring $RING ${kms[*]} --output-file $PUB"
  echo
  echo "Nothing was changed. Run again with --yes to do the steps above."
fi
