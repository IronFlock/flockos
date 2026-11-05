#!/usr/bin/env bash
# Stage 1: the root filesystem tree in $ROOT, with mmdebstrap (master plan,
# section 3.3). Debian 13 minbase plus the profile's packages, Docker CE from
# download.docker.com at the pinned versions; no Recommends.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${ARCH:?}" "${VARIANT:?}" "${TARGET:?}" "${BOOTLOADER:?}"
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

mapfile -t packages < <(read_list "$profile/packages" "$profile/packages.$ARCH" "$src/targets/$TARGET/packages")
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

hooks=()
if [ "$BOOTLOADER" = rpi ]; then
  # The Raspberry Pi archive, below Debian: it also carries rebuilds of
  # Debian packages, and Debian's win, except for the two both have that
  # must be the Pi's: its raspi-firmware (Debian's is older and ships NVRAM
  # files of its own) and the WiFi firmware with the Pi boards' NVRAM files.
  # What only the archive has (kernels, EEPROM tools) comes from it anyway.
  : "${RPI_MIRROR:?}"
  {
    echo "Types: deb"
    echo "URIs: $RPI_MIRROR"
    echo "Suites: $DEBIAN_SUITE"
    echo "Components: main"
    echo "Architectures: $ARCH"
    echo "Signed-By:"
    sed -e 's/^$/./' -e 's/^/ /' "$src/targets/$TARGET/apt/raspberrypi.asc"
  } >"$sources/raspberrypi.sources"
  rpi_host=${RPI_MIRROR#*://}
  rpi_host=${rpi_host%%/*}
  pref=$WORK/flockos-raspberrypi.pref
  printf 'Package: *\nPin: origin %s\nPin-Priority: 100\n\nPackage: raspi-firmware firmware-brcm80211\nPin: origin %s\nPin-Priority: 990\n' \
    "$rpi_host" "$rpi_host" >"$pref"
  # shellcheck disable=SC2016 # "$1" is mmdebstrap's, the tree's path
  hooks+=(
    --setup-hook='mkdir -p "$1/etc/apt/preferences.d"'
    --setup-hook="copy-in $pref /etc/apt/preferences.d"
  )
fi

# Debian first, then the others (Docker, and the Pi's archive on rpi-arm64).
mapfile -t other_sources < <(find "$sources" -name '*.sources' ! -name debian.sources | sort)
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
  "${hooks[@]}" \
  "$DEBIAN_SUITE" "$ROOT" \
  "$sources/debian.sources" "${other_sources[@]}"

# The sources the device keeps (mmdebstrap writes its own file).
rm -f "$ROOT/etc/apt/sources.list"
rm -f "$ROOT"/etc/apt/sources.list.d/*
cp "$sources"/*.sources "$ROOT/etc/apt/sources.list.d/"
chmod 0644 "$ROOT"/etc/apt/sources.list.d/*.sources
log "rootfs: $(du -sh --apparent-size "$ROOT" | cut -f1), ${#packages[@]} packages requested"
