#!/usr/bin/env bash
# Stage 1: the root filesystem tree in $ROOT, with mmdebstrap (master plan,
# section 3.3). Debian 13 minbase plus the profile's packages, Docker CE from
# download.docker.com at the pinned versions; no Recommends.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${ARCH:?}" "${VARIANT:?}" "${KERNEL:?}"
require mmdebstrap

profile=$src/profiles/base
sources=$WORK/apt
mkdir -p "$sources"

# Debian and Docker as deb822 sources. Docker's key is embedded in
# Signed-By, so the same file works for the build and on the device.
cat >"$sources/debian.sources" <<SOURCES
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $DEBIAN_SUITE $DEBIAN_SUITE-updates
Components: $DEBIAN_COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $DEBIAN_SECURITY_MIRROR
Suites: $DEBIAN_SUITE-security
Components: $DEBIAN_COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
{
  echo "Types: deb"
  echo "URIs: $DOCKER_MIRROR"
  echo "Suites: $DEBIAN_SUITE"
  echo "Components: stable"
  echo "Architectures: $ARCH"
  echo "Signed-By:"
  sed -e 's/^$/./' -e 's/^/ /' "$profile/apt/docker.asc"
} >"$sources/docker.sources"

mapfile -t packages < <(read_list "$profile/packages" "$profile/packages.$ARCH")
# The rt kernel axis (section 3.11): Debian's PREEMPT_RT kernel instead of the
# standard one, plus profiles/kernel-rt.
if [ "$KERNEL" = rt ]; then
  rt=$src/profiles/kernel-rt
  mapfile -t packages < <(printf '%s\n' "${packages[@]}" | grep -v '^linux-image-')
  mapfile -t -O "${#packages[@]}" packages < <(read_list "$rt/packages" "$rt/packages.$ARCH")
  printf '%s\n' "${packages[@]}" | grep -q '^linux-image-rt-' || die "no rt kernel for $ARCH in profiles/kernel-rt"
fi
pin() { # pin PACKAGE VERSION: replace PACKAGE with PACKAGE=VERSION
  local i found=0
  for i in "${!packages[@]}"; do
    if [ "${packages[$i]}" = "$1" ]; then
      packages[i]="$1=$2"
      found=1
    fi
  done
  [ "$found" = 1 ] || die "pin: $1 is not in the package list"
}
pin docker-ce "$DOCKER_CE_VERSION"
pin docker-ce-cli "$DOCKER_CE_VERSION"
pin containerd.io "$CONTAINERD_VERSION"
pin docker-buildx-plugin "$BUILDX_VERSION"
pin docker-compose-plugin "$COMPOSE_VERSION"

rm -rf "$ROOT"
mmdebstrap \
  --mode=root \
  --variant=minbase \
  --architectures="$ARCH" \
  --format=directory \
  --aptopt='APT::Install-Recommends "false"' \
  --aptopt='Acquire::Retries "5"' \
  --include="$(join_by , "${packages[@]}")" \
  --skip=check/empty \
  "$DEBIAN_SUITE" "$ROOT" \
  "$sources/debian.sources" "$sources/docker.sources"

# The sources the device keeps (mmdebstrap writes its own file).
rm -f "$ROOT/etc/apt/sources.list"
rm -f "$ROOT"/etc/apt/sources.list.d/*
cp "$sources/debian.sources" "$sources/docker.sources" "$ROOT/etc/apt/sources.list.d/"
chmod 0644 "$ROOT"/etc/apt/sources.list.d/*.sources
log "rootfs: $(du -sh --apparent-size "$ROOT" | cut -f1), ${#packages[@]} packages requested"
