#!/usr/bin/env bash
# Retires what IronFlockOS published and set up under its old name flockos
# (ADR-0017), once the new tree dl/ironflockos/ and the clients that read it
# are live. Run by a project owner.
#
#   tools/retire-old-names.sh            show what would be done
#   tools/retire-old-names.sh --yes      do it
#
# Removes (cannot be undone):
#   gs://ironflock-downloads/flockos/ and gs://ironflock-downloads/staging/flockos/,
#     the releases up to 0.15.0 and their catalog
#   the Compute Engine images named flockos-* in the project
# Disables (can be enabled again):
#   the KMS key versions ironflock-release/flockos-catalog,
#     flockos-rauc/bundle-signer and flockos-rauc-ca/root
#   the service accounts flockos-release and flockos-publisher
# Deletes (restorable for 7 days): the custom role flockosVmImagePublisher.
#
# Not here, in other repositories: the route /dl/flockos/ of registry-proxy.
#
# It refuses while the new catalog does not answer through the download proxy.
# Needs gcloud (authenticated as a project owner) and curl.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$repo/build/lib.sh"
load_conf "$repo/build/release.conf"
PROJECT=${PROJECT:-$GCE_PROJECT}
LOCATION=${LOCATION:-europe-west1}
OLD=flockos
yes=0
[ "${1:-}" = --yes ] && yes=1
gcloud=${GCLOUD:-gcloud}
command -v "$gcloud" >/dev/null || gcloud=$HOME/google-cloud-sdk/bin/gcloud

do_() {
  printf '+ %s\n' "$*"
  if [ "$yes" = 1 ]; then "$@"; fi
}
exists() { "$gcloud" "$@" >/dev/null 2>&1; }

curl -fsS --proto '=https' -o /dev/null "$DL_BASE/ironflockos/manifest.json" ||
  die "$DL_BASE/ironflockos/manifest.json does not answer: the new tree is not live, nothing is retired"

echo "== the old download trees"
for tree in "$BUCKET/$OLD/" "$BUCKET/staging/$OLD/"; do
  if exists storage ls "$tree"; then
    do_ "$gcloud" storage rm --recursive --quiet "$tree"
  else
    echo "$tree: gone already"
  fi
done

echo "== the old Compute Engine images"
"$gcloud" compute images list --project "$PROJECT" --no-standard-images \
  --filter="name ~ ^$OLD-" --format='value(name)' | while read -r image; do
  do_ "$gcloud" compute images delete "$image" --project "$PROJECT" --quiet
done

echo "== the old keys"
kms=(--project "$PROJECT" --location "$LOCATION")
for k in ironflock-release/$OLD-catalog $OLD-rauc/bundle-signer $OLD-rauc-ca/root; do
  ring=${k%/*} key=${k#*/}
  state=$("$gcloud" kms keys versions describe 1 --key "$key" --keyring "$ring" "${kms[@]}" --format='value(state)' 2>/dev/null || echo MISSING)
  case "$state" in
    ENABLED) do_ "$gcloud" kms keys versions disable 1 --key "$key" --keyring "$ring" "${kms[@]}" ;;
    *) echo "$k version 1: $state" ;;
  esac
done

echo "== the old service accounts and role"
for sa in $OLD-release $OLD-publisher; do
  email=$sa@$PROJECT.iam.gserviceaccount.com
  if exists iam service-accounts describe "$email" --project "$PROJECT"; then
    do_ "$gcloud" iam service-accounts disable "$email" --project "$PROJECT"
  else
    echo "$email: gone already"
  fi
done
role=${OLD}VmImagePublisher
if exists iam roles describe "$role" --project "$PROJECT"; then
  do_ "$gcloud" iam roles delete "$role" --project "$PROJECT"
else
  echo "role $role: gone already"
fi

[ "$yes" = 1 ] || echo "Nothing was changed. Run again with --yes to do the steps above."
