#!/usr/bin/env bash
# Stage 1: the root filesystem tree in $ROOT, with mmdebstrap (master plan,
# section 3.3). Debian 13 minbase plus the profile's packages, Docker CE from
# download.docker.com at the pinned versions; no Recommends. The nvidia
# variant adds NVIDIA's repositories, its driver and container toolkit at the
# versions of profiles/nvidia/versions, and builds the open kernel modules in
# the tree (build/nvidia-modules.sh).
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

variant_profile=$src/profiles/$VARIANT
mapfile -t packages < <(read_list "$profile/packages" "$profile/packages.$ARCH" \
  "$src/targets/$TARGET/packages" "$variant_profile/packages" "$variant_profile/packages.$ARCH")
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

# flat_source NAME URI KEY: a deb822 source for a flat repository (no suite,
# no components) with KEY embedded in Signed-By.
flat_source() {
  {
    echo "Types: deb"
    echo "URIs: $2/"
    echo "Suites: /"
    echo "Signed-By:"
    sed -e 's/^$/./' -e 's/^/ /' "$3"
  } >"$sources/$1.sources"
}
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
if [ "$VARIANT" = nvidia ]; then
  [ "$ARCH" = amd64 ] || die "the nvidia variant is built for amd64 only"
  : "${NVIDIA_CUDA_MIRROR:?}" "${NVIDIA_CTK_MIRROR:?}" "${NVIDIA_DRIVER_VERSION:?}" "${NVIDIA_CONTAINER_TOOLKIT_VERSION:?}"
  flat_source cuda "$NVIDIA_CUDA_MIRROR" "$variant_profile/apt/cuda.asc"
  flat_source nvidia-container-toolkit "$NVIDIA_CTK_MIRROR" "$variant_profile/apt/nvidia-container-toolkit.asc"
  for p in nvidia-driver-cuda nvidia-kernel-support firmware-nvidia-gsp; do
    pin "$p" "$NVIDIA_DRIVER_VERSION"
  done
  for p in nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1; do
    pin "$p" "$NVIDIA_CONTAINER_TOOLKIT_VERSION"
  done
  # The command line pins only what is listed; apt's solver would take the
  # newest version of every other binary of the driver (exact-version
  # dependencies, no backtracking). These pins hold every binary of NVIDIA's
  # source packages at the profile's version, in the build and on the device.
  pref=$WORK/flockos-nvidia.pref
  {
    for p in nvidia-graphics-drivers nvidia-kmod-open nvidia-modprobe nvidia-persistenced; do
      printf 'Package: src:%s\nPin: version %s\nPin-Priority: 1001\n\n' "$p" "$NVIDIA_DRIVER_VERSION"
    done
    for p in libnvidia-container nvidia-container-toolkit; do
      printf 'Package: src:%s\nPin: version %s\nPin-Priority: 1001\n\n' "$p" "$NVIDIA_CONTAINER_TOOLKIT_VERSION"
    done
  } >"$pref"
  # shellcheck disable=SC2016 # "$1" is mmdebstrap's, the tree's path
  hooks+=(
    --setup-hook='mkdir -p "$1/etc/apt/preferences.d"'
    --setup-hook="copy-in $pref /etc/apt/preferences.d"
    --customize-hook="upload $here/nvidia-modules.sh /tmp/flockos-nvidia-modules.sh"
    --chrooted-customize-hook="bash /tmp/flockos-nvidia-modules.sh $NVIDIA_DRIVER_VERSION"
    --customize-hook='rm -f "$1/tmp/flockos-nvidia-modules.sh"'
  )
fi

# Debian first, then the others (Docker, the Pi's archive on rpi-arm64,
# NVIDIA's for nvidia).
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
