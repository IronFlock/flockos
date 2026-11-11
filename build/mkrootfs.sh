#!/usr/bin/env bash
# Stage 1: the root filesystem tree in $ROOT, with mmdebstrap (master plan,
# section 3.3). The minbase of the target's distribution (distros/$DISTRO:
# Debian 13 unless target.conf names another) plus the profile's packages,
# Docker CE from download.docker.com at the pinned versions; no Recommends. The nvidia
# variant adds NVIDIA's repositories, its driver and container toolkit at the
# versions of profiles/nvidia/versions, and builds the open kernel modules in
# the tree (build/nvidia-modules.sh).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"
: "${ROOT:?}" "${WORK:?}" "${ARCH:?}" "${VARIANT:?}" "${KERNEL:?}" "${TARGET:?}" "${BOOTLOADER:?}"
: "${DISTRO_ID:?}" "${DISTRO_SUITE:?}" "${DISTRO_MIRROR:?}" "${DISTRO_SECURITY_MIRROR:?}" "${DISTRO_COMPONENTS:?}" "${DISTRO_KEYRING:?}" "${DOCKER_MIRROR:?}"
require mmdebstrap

profile=$src/profiles/base
sources=$WORK/apt
mkdir -p "$sources"

# The distribution (debian.sources, ubuntu.sources) and Docker as deb822
# sources. The distribution's keyring is a file of its archive-keyring
# package, on the builder and on the device; Docker's key is embedded in
# Signed-By, so the same file works for the build and on the device.
distro_sources=$sources/$DISTRO_ID.sources
cat >"$distro_sources" <<SOURCES
Types: deb
URIs: $DISTRO_MIRROR
Suites: $DISTRO_SUITE $DISTRO_SUITE-updates
Components: $DISTRO_COMPONENTS
Signed-By: $DISTRO_KEYRING

Types: deb
URIs: $DISTRO_SECURITY_MIRROR
Suites: $DISTRO_SUITE-security
Components: $DISTRO_COMPONENTS
Signed-By: $DISTRO_KEYRING
SOURCES
{
  echo "Types: deb"
  echo "URIs: $DOCKER_MIRROR"
  echo "Suites: $DISTRO_SUITE"
  echo "Components: stable"
  echo "Architectures: $ARCH"
  echo "Signed-By:"
  sed -e 's/^$/./' -e 's/^/ /' "$profile/apt/docker.asc"
} >"$sources/docker.sources"

variant_profile=$src/profiles/$VARIANT
mapfile -t packages < <(read_list "$profile/packages" "$profile/packages.$DISTRO_ID" "$profile/packages.$ARCH" \
  "$src/targets/$TARGET/packages" "$variant_profile/packages" "$variant_profile/packages.$ARCH")
# The rt kernel axis (section 3.11): Debian's PREEMPT_RT kernel instead of the
# target's standard one, plus profiles/kernel-rt.
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
    echo "Suites: $DISTRO_SUITE"
    echo "Components: main"
    echo "Architectures: $ARCH"
    echo "Signed-By:"
    sed -e 's/^$/./' -e 's/^/ /' "$src/targets/$TARGET/apt/raspberrypi.asc"
  } >"$sources/raspberrypi.sources"
  rpi_host=${RPI_MIRROR#*://}
  rpi_host=${rpi_host%%/*}
  pref=$WORK/ironflockos-raspberrypi.pref
  printf 'Package: *\nPin: origin %s\nPin-Priority: 100\n\nPackage: raspi-firmware firmware-brcm80211\nPin: origin %s\nPin-Priority: 990\n' \
    "$rpi_host" "$rpi_host" >"$pref"
  # shellcheck disable=SC2016 # "$1" is mmdebstrap's, the tree's path
  hooks+=(
    --setup-hook='mkdir -p "$1/etc/apt/preferences.d"'
    --setup-hook="copy-in $pref /etc/apt/preferences.d"
  )
fi
if [ "$BOOTLOADER" = tegra ]; then
  # NVIDIA's L4T repositories (ADR-0008), below the distribution like the
  # Pi's archive: what both have comes from Ubuntu. They carry several L4T
  # releases; the pins hold every L4T binary at the target's versions (the
  # kernel's own version for the kernel's), and the container toolkit at
  # its, in the build and on the device. The packages the target lists are
  # pinned on the command line too, so a version NVIDIA withdrew fails the
  # build instead of the pin matching nothing.
  : "${L4T_MIRROR:?}" "${L4T_SUITE:?}" "${L4T_PACKAGE_VERSION:?}" "${L4T_KERNEL_VERSION:?}" "${L4T_CONTAINER_TOOLKIT_VERSION:?}"
  {
    echo "Types: deb"
    echo "URIs: $L4T_MIRROR/common $L4T_MIRROR/som"
    echo "Suites: $L4T_SUITE"
    echo "Components: main"
    echo "Architectures: $ARCH"
    echo "Signed-By:"
    # the key block only: NVIDIA's file starts with a licence header
    sed -n '/^-----BEGIN PGP PUBLIC KEY BLOCK-----$/,/^-----END PGP PUBLIC KEY BLOCK-----$/p' \
      "$src/targets/$TARGET/apt/jetson-ota-public.asc" | sed -e 's/^$/./' -e 's/^/ /'
  } >"$sources/nvidia-l4t.sources"
  l4t_host=${L4T_MIRROR#*://}
  l4t_host=${l4t_host%%/*}
  l4t_kernel_pkgs="nvidia-l4t-kernel nvidia-l4t-kernel-* nvidia-l4t-display-kernel"
  toolkit_pkgs="nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1"
  pref=$WORK/ironflockos-l4t.pref
  {
    printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n\n' "$l4t_kernel_pkgs" "$L4T_KERNEL_VERSION"
    printf 'Package: nvidia-l4t-*\nPin: version %s\nPin-Priority: 1001\n\n' "$L4T_PACKAGE_VERSION"
    printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n\n' "$toolkit_pkgs" "$L4T_CONTAINER_TOOLKIT_VERSION"
    printf 'Package: *\nPin: origin %s\nPin-Priority: 100\n' "$l4t_host"
  } >"$pref"
  for name in "${packages[@]}"; do
    case "$name" in
      nvidia-l4t-kernel | nvidia-l4t-kernel-* | nvidia-l4t-display-kernel) pin "$name" "$L4T_KERNEL_VERSION" ;;
      nvidia-l4t-*) pin "$name" "$L4T_PACKAGE_VERSION" ;;
      nvidia-container-toolkit | nvidia-container-toolkit-base | libnvidia-container-tools | libnvidia-container1)
        pin "$name" "$L4T_CONTAINER_TOOLKIT_VERSION"
        ;;
    esac
  done
  # NVIDIA's packages check the board they are installed on (nvidia-l4t-core
  # refuses anything but a Jetson) and update its boot firmware unless this
  # marker exists, as in NVIDIA's own image build; it goes again once the
  # packages are in.
  l4t_marker=/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall
  # shellcheck disable=SC2016 # "$1" is mmdebstrap's, the tree's path
  hooks+=(
    --setup-hook='mkdir -p "$1/etc/apt/preferences.d" "$1/opt/nvidia/l4t-packages"'
    --setup-hook="copy-in $pref /etc/apt/preferences.d"
    --setup-hook='touch "$1'"$l4t_marker"'"'
    --customize-hook='rm -f "$1'"$l4t_marker"'"'
  )
fi
if [ "$VARIANT" = nvidia ]; then
  [ "$ARCH" = amd64 ] || die "the nvidia variant is built for amd64 only"
  [ "$DISTRO_ID" = debian ] || die "the nvidia variant is built on Debian only (NVIDIA's repositories in profiles/nvidia are Debian's)"
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
  pref=$WORK/ironflockos-nvidia.pref
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
    --customize-hook="upload $here/nvidia-modules.sh /tmp/ironflockos-nvidia-modules.sh"
    --chrooted-customize-hook="bash /tmp/ironflockos-nvidia-modules.sh $NVIDIA_DRIVER_VERSION"
    --customize-hook='rm -f "$1/tmp/ironflockos-nvidia-modules.sh"'
  )
fi

# The distribution first, then the others (Docker, the Pi's archive on
# rpi-arm64, NVIDIA's for nvidia).
mapfile -t other_sources < <(find "$sources" -name '*.sources' ! -name "$DISTRO_ID.sources" | sort)
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
  "$DISTRO_SUITE" "$ROOT" \
  "$distro_sources" "${other_sources[@]}"

# The sources the device keeps (mmdebstrap writes its own file).
rm -f "$ROOT/etc/apt/sources.list"
rm -f "$ROOT"/etc/apt/sources.list.d/*
cp "$sources"/*.sources "$ROOT/etc/apt/sources.list.d/"
chmod 0644 "$ROOT"/etc/apt/sources.list.d/*.sources
log "rootfs: $(du -sh --apparent-size "$ROOT" | cut -f1), ${#packages[@]} packages requested"
