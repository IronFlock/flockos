#!/usr/bin/env bats
# The distributions of distros/ (WP-6.2): what build/build.sh and
# build/mkrootfs.sh read from each, and what keeps the Debian images as they
# were.

repo="$BATS_TEST_DIRNAME/../.."

setup() {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
}

@test "every distribution names its archive, keyring and Docker pins" {
  for d in "$repo"/distros/*/; do
    (
      name=$(basename "$d")
      load_conf "$d/versions"
      [[ "$name" == "$DISTRO_ID-$DISTRO_SUITE" ]]
      [[ " $DISTRO_ID_LIKE " == *" $DISTRO_ID "* ]] || [ "$DISTRO_ID" = debian ]
      [[ " $DISTRO_ID_LIKE " == *" debian "* ]]
      [[ "$DISTRO_MIRROR" == http*://* ]] && [[ "$DISTRO_SECURITY_MIRROR" == http*://* ]]
      [ -n "$DISTRO_COMPONENTS" ]
      [[ "$DISTRO_KEYRING" == /usr/share/keyrings/*.gpg ]]
      [ "$DOCKER_MIRROR" = "https://download.docker.com/linux/$DISTRO_ID" ]
      for v in "$DOCKER_CE_VERSION" "$CONTAINERD_VERSION" "$BUILDX_VERSION" "$COMPOSE_VERSION"; do
        [[ "$v" == *"~$DISTRO_SUITE" ]]
      done
    )
  done
}

@test "the builder carries every distribution's archive keyring" {
  mapfile -t builder < <(read_list "$repo/build/builder-packages")
  for d in "$repo"/distros/*/; do
    (
      load_conf "$d/versions"
      case "$DISTRO_ID" in
        debian) pkg=debian-archive-keyring ;;
        ubuntu) pkg=ubuntu-keyring ;;
        *) false ;;
      esac
      printf '%s\n' "${builder[@]}" | grep -qx "$pkg"
    )
  done
}

@test "Debian 13 is the default and keeps the pins and packages it had" {
  load_conf "$repo/distros/debian-trixie/versions"
  [ "$DISTRO_SUITE" = trixie ]
  [ "$DISTRO_KEYRING" = /usr/share/keyrings/debian-archive-keyring.gpg ]
  [[ "$DOCKER_CE_VERSION" == *"~debian.13~trixie" ]]
  grep -q '^DISTRO=${DISTRO:-debian-trixie}$' "$repo/build/build.sh"
  mapfile -t deb < <(read_list "$repo/profiles/base/packages.debian")
  printf '%s\n' "${deb[@]}" | grep -qx systemd-repart
  printf '%s\n' "${deb[@]}" | grep -qx firmware-misc-nonfree
}

@test "the per-distribution package lists add to the base list, never repeat it" {
  mapfile -t base < <(read_list "$repo/profiles/base/packages")
  for f in "$repo"/profiles/base/packages.*; do
    case "$f" in *.amd64 | *.arm64) continue ;; esac
    id=${f##*.}
    [ -d "$repo/distros" ] && compgen -G "$repo/distros/$id-*" >/dev/null
    while read -r p; do
      ! printf '%s\n' "${base[@]}" | grep -qx "$p"
    done < <(read_list "$f")
  done
}

@test "the base profile no longer pins the distribution" {
  ! grep -qE '^(DEBIAN_|DISTRO_|DOCKER_|CONTAINERD_|BUILDX_|COMPOSE_)' "$repo/profiles/base/versions"
}

@test "a target names a distribution that exists, or none" {
  for t in "$repo"/targets/*/target.conf; do
    (
      unset DISTRO
      load_conf "$t"
      [ -z "${DISTRO:-}" ] || [ -f "$repo/distros/$DISTRO/versions" ]
    )
  done
}

@test "os-release takes ID_LIKE from the distribution" {
  run bash "$repo/build/osrelease.sh" 1.2.3 amd64-efi base std 1a2b3c4 1793000000
  [ "$status" -eq 0 ] && [[ "$output" == *$'\nID_LIKE=debian\n'* ]]
  DISTRO_ID_LIKE="ubuntu debian" run bash "$repo/build/osrelease.sh" 1.2.3 amd64-efi base std 1a2b3c4 1793000000
  [ "$status" -eq 0 ] && [[ "$output" == *$'\nID_LIKE="ubuntu debian"\n'* ]]
  DISTRO_ID_LIKE='debian"; x' run bash "$repo/build/osrelease.sh" 1.2.3 amd64-efi base std 1a2b3c4 1793000000
  [ "$status" -ne 0 ] && [[ "$output" == *"not an ID_LIKE list"* ]]
}

@test "mkrootfs writes the distribution's sources and refuses nvidia off Debian" {
  grep -q 'distro_sources=$sources/$DISTRO_ID.sources' "$repo/build/mkrootfs.sh"
  grep -q 'Signed-By: $DISTRO_KEYRING' "$repo/build/mkrootfs.sh"
  grep -q '"$profile/packages.$DISTRO_ID"' "$repo/build/mkrootfs.sh"
  grep -q 'the nvidia variant is built on Debian only' "$repo/build/mkrootfs.sh"
  ! grep -E 'DEBIAN_(SUITE|MIRROR|SECURITY_MIRROR|COMPONENTS)' "$repo/build/mkrootfs.sh"
}
