#!/usr/bin/env bash
# Fetch the NVIDIA Jetson Linux BSP pinned in targets/jetson-orin/bsp.conf
# (ADR-0008; WP-6.1) and unpack it.
#   fetch-bsp.sh CACHE_DIR [DEST_DIR]
#
# CACHE_DIR keeps the tarball between builds (CI caches it keyed on
# L4T_VERSION); a cached tarball is downloaded again only when it fails the
# checks. DEST_DIR, if given, gets Linux_for_Tegra/.
#
# A tarball is used only when its SHA-256 is the pinned one and its SHA-1 the
# pinned one. When NVIDIA's release_sha_hashes.txt can be fetched, it must
# still list that SHA-1: a republished BSP fails the build instead of
# slipping in.
#
# FLOCKOS_BSP_CONF: for the unit tests.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  die "usage: fetch-bsp.sh CACHE_DIR [DEST_DIR]"
fi
cache=$1
dest=${2:-}
load_conf "${FLOCKOS_BSP_CONF:-$src/targets/jetson-orin/bsp.conf}"
: "${L4T_VERSION:?}" "${BSP_URL:?}" "${BSP_HASHES_URL:?}" "${BSP_SHA1:?}" "${BSP_SHA256:?}"
require curl sha256sum sha1sum tar

name=${BSP_URL##*/}
file=$cache/$name
mkdir -p "$cache"

# NVIDIA's list, when it can be had (an offline rebuild from the cache still
# works on the pinned hashes alone).
if listed=$(curl -fsSL --proto '=https,file' --retry 3 "$BSP_HASHES_URL" 2>/dev/null); then
  nvidia_sha1=$(printf '%s\n' "$listed" | awk -v n="$name" '{ f = $2; sub(/^\*?(\.\/)?/, "", f) } f == n { print $1; exit }')
  [ -n "$nvidia_sha1" ] || die "NVIDIA's release_sha_hashes.txt does not list $name"
  [ "$nvidia_sha1" = "$BSP_SHA1" ] ||
    die "NVIDIA lists SHA-1 $nvidia_sha1 for $name, the pin is $BSP_SHA1: the BSP was republished"
else
  warn "cannot fetch $BSP_HASHES_URL; checking against the pinned hashes only"
fi

verified() {
  [ -f "$1" ] &&
    echo "$BSP_SHA256  $1" | sha256sum -c --quiet - >/dev/null 2>&1 &&
    echo "$BSP_SHA1  $1" | sha1sum -c --quiet - >/dev/null 2>&1
}

if verified "$file"; then
  log "BSP $L4T_VERSION: $name from the cache"
else
  rm -f "$file"
  log "BSP $L4T_VERSION: downloading $name"
  curl -fsSL --proto '=https,file' --retry 5 --retry-all-errors -o "$file.part" "$BSP_URL" ||
    die "cannot download $BSP_URL"
  mv "$file.part" "$file"
  if ! verified "$file"; then
    rm -f "$file"
    die "$name does not match the pinned SHA-256 and SHA-1 (targets/jetson-orin/bsp.conf)"
  fi
  log "BSP $L4T_VERSION: $name verified"
fi

if [ -n "$dest" ]; then
  mkdir -p "$dest"
  rm -rf "$dest/Linux_for_Tegra"
  # lbzip2 unpacks in parallel where it is installed.
  if command -v lbzip2 >/dev/null; then
    tar -I lbzip2 -xf "$file" -C "$dest"
  else
    tar -xjf "$file" -C "$dest"
  fi
  [ -x "$dest/Linux_for_Tegra/l4t_initrd_flash.sh" ] || die "$name has no Linux_for_Tegra/l4t_initrd_flash.sh"
  log "BSP $L4T_VERSION: unpacked to $dest/Linux_for_Tegra"
fi
