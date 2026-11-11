#!/usr/bin/env bash
# Run build/sign-bundles.sh in the build container (build/builder.conf).
#   sign-in-builder.sh release|dry-run [DIR]
#
# DIR (default out) holds the images of a release build, one directory each.
# For release, GOOGLE_APPLICATION_CREDENTIALS names the credentials file of
# the workload identity (google-github-actions/auth in release.yml); it is
# mounted read-only. Always linux/amd64: Google's PKCS#11 library exists for
# amd64 only.
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
