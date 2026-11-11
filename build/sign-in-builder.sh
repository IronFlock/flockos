#!/usr/bin/env bash
# Run build/sign-bundles.sh in the build container (build/builder.conf), then
# build/verify-bundles.sh in another: every bundle as signed against the
# keyring its image carries.
#   sign-in-builder.sh release|dry-run [DIR]
#
# DIR (default out) holds the images of a release build, one directory each.
# For release, GOOGLE_APPLICATION_CREDENTIALS names the credentials file of
# the workload identity (google-github-actions/auth in release.yml); it is
# mounted read-only into the container that signs, and only there. The check
# reads the images' file systems, which a pull request's run may have built:
# it gets DIR read-only and, of the repository, only the files it reads
# (build/verify-bundles.sh, build/lib.sh, pki/). Not the whole working tree,
# where google-github-actions/auth leaves its credentials file
# (gha-creds-*.json, a token for the release identity). IRONFLOCKOS_WORK,
# when set, is the scratch space of the check, which unpacks each image
# there. Always linux/amd64: Google's PKCS#11 library exists for amd64 only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

mode=${1:-}
case "$mode" in
  release | dry-run) ;;
  *) die "usage: sign-in-builder.sh release|dry-run [DIR]" ;;
esac
out=${2:-$repo/out}
[ -d "$out" ] || die "$out is no directory"
out=$(cd "$out" && pwd)
require docker
load_conf "$here/builder.conf"

creds=()
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ] || die "GOOGLE_APPLICATION_CREDENTIALS names no file"
  creds=(-v "$GOOGLE_APPLICATION_CREDENTIALS:/run/ironflockos/gcp-credentials.json:ro"
    -e GOOGLE_APPLICATION_CREDENTIALS=/run/ironflockos/gcp-credentials.json)
fi
scratch=()
if [ -n "${IRONFLOCKOS_WORK:-}" ]; then
  [ -d "$IRONFLOCKOS_WORK" ] || die "IRONFLOCKOS_WORK names no directory"
  scratch=(-v "$(cd "$IRONFLOCKOS_WORK" && pwd):/work" -e IRONFLOCKOS_WORK=/work)
fi

log "signing the bundles in $out ($mode) in $BUILDER_IMAGE"
# shellcheck disable=SC2016 # expanded by the container's shell
docker run --rm \
  --platform linux/amd64 \
  -v "$repo:/src:ro" \
  -v "$out:/out" \
  ${creds[@]+"${creds[@]}"} \
  -e IRONFLOCKOS_HOST_UID="$(id -u)" \
  -e IRONFLOCKOS_HOST_GID="$(id -g)" \
  -e DEBIAN_FRONTEND=noninteractive \
  "$BUILDER_IMAGE" \
  bash -c 'set -e
    apt-get -qq -o Acquire::Retries=5 update
    apt-get -qq -y -o Acquire::Retries=5 install --no-install-recommends \
      rauc openssl libengine-pkcs11-openssl curl ca-certificates >/dev/null
    exec bash /src/build/sign-bundles.sh "$1" /out' sign "$mode"

log "checking the signed bundles in $out against their images' keyrings ($mode)"
# shellcheck disable=SC2016 # expanded by the container's shell
docker run --rm \
  --platform linux/amd64 \
  -v "$repo/build/verify-bundles.sh:/src/build/verify-bundles.sh:ro" \
  -v "$repo/build/lib.sh:/src/build/lib.sh:ro" \
  -v "$repo/pki:/src/pki:ro" \
  -v "$out:/out:ro" \
  ${scratch[@]+"${scratch[@]}"} \
  -e DEBIAN_FRONTEND=noninteractive \
  "$BUILDER_IMAGE" \
  bash -c 'set -e
    apt-get -qq -o Acquire::Retries=5 update
    apt-get -qq -y -o Acquire::Retries=5 install --no-install-recommends \
      rauc openssl e2fsprogs fdisk jq >/dev/null
    exec bash /src/build/verify-bundles.sh "$1" /out' verify "$mode"
