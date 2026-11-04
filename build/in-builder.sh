#!/usr/bin/env bash
# Entry point inside the build container: install the build tools, then run
# build/build.sh. Called by build/run-in-builder.sh only.
set -euo pipefail
src=/src
# shellcheck source=build/lib.sh
. "$src/build/lib.sh"

arch=$(dpkg --print-architecture)
export DEBIAN_FRONTEND=noninteractive
log "installing the build tools ($arch)"
apt-get -qq -o Acquire::Retries=5 update
# shellcheck disable=SC2046 # package names, one per word
apt-get -qq -y -o Acquire::Retries=5 install --no-install-recommends \
  $(read_list "$src/build/builder-packages" "$src/build/builder-packages.$arch") >/dev/null

# apt runs mmdebstrap's hooks with the container's /bin/sh. Under CPU
# emulation (an amd64 build on an arm64 Mac) every process holds extra file
# descriptors, the hooks get descriptors above 9, and dash refuses those.
# Only the build container's shell changes; the image keeps Debian's.
ln -sf bash /bin/sh

exec bash "$src/build/build.sh" "$@"
