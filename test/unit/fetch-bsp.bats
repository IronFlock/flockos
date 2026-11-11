#!/usr/bin/env bats
# build/fetch-bsp.sh (WP-6.1) against a fake BSP served from file:// URLs:
# download, cache, the pinned hashes, NVIDIA's list.

repo="$BATS_TEST_DIRNAME/../.."
fetch="$repo/build/fetch-bsp.sh"

setup() {
  dir=$(mktemp -d)
  name=Jetson_Linux_R39.2.1_aarch64.tbz2
  mkdir -p "$dir/src/Linux_for_Tegra" "$dir/www"
  printf '#!/bin/sh\n' >"$dir/src/Linux_for_Tegra/l4t_initrd_flash.sh"
  chmod +x "$dir/src/Linux_for_Tegra/l4t_initrd_flash.sh"
  tar -cjf "$dir/www/$name" -C "$dir/src" Linux_for_Tegra
  sha1=$(sha1sum "$dir/www/$name" | cut -d' ' -f1)
  sha256=$(sha256sum "$dir/www/$name" | cut -d' ' -f1)
  printf '%s *./%s\n0000000000000000000000000000000000000000 *./other.tbz2\n' "$sha1" "$name" >"$dir/www/release_sha_hashes.txt"
  conf "$sha256" "$sha1" "file://$dir/www/release_sha_hashes.txt"
}

teardown() { rm -rf "$dir"; }

# conf SHA256 SHA1 HASHES_URL
conf() {
  export IRONFLOCKOS_BSP_CONF=$dir/bsp.conf
  printf 'L4T_VERSION=39.2.1\nBSP_URL=file://%s/www/%s\nBSP_HASHES_URL=%s\nBSP_SHA1=%s\nBSP_SHA256=%s\n' \
    "$dir" "$name" "$3" "$2" "$1" >"$IRONFLOCKOS_BSP_CONF"
}

@test "downloads, verifies and unpacks the BSP" {
  run "$fetch" "$dir/cache" "$dir/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified"* ]]
  [ -f "$dir/cache/$name" ] && [ ! -e "$dir/cache/$name.part" ]
  [ -x "$dir/out/Linux_for_Tegra/l4t_initrd_flash.sh" ]
}

@test "a verified tarball in the cache is not downloaded again" {
  "$fetch" "$dir/cache"
  mv "$dir/www/$name" "$dir/gone.tbz2"
  run "$fetch" "$dir/cache" "$dir/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from the cache"* ]]
  [ -x "$dir/out/Linux_for_Tegra/l4t_initrd_flash.sh" ]
}

@test "a tarball that is not the pinned one fails and leaves nothing in the cache" {
  conf 0000000000000000000000000000000000000000000000000000000000000000 "$sha1" "file://$dir/www/release_sha_hashes.txt"
  run "$fetch" "$dir/cache"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the pinned"* ]]
  [ ! -e "$dir/cache/$name" ]
}

@test "a BSP NVIDIA has republished under the same name fails" {
  printf '1111111111111111111111111111111111111111 *./%s\n' "$name" >"$dir/www/release_sha_hashes.txt"
  run "$fetch" "$dir/cache"
  [ "$status" -ne 0 ]
  [[ "$output" == *"republished"* ]]
}

@test "without NVIDIA's list the pinned hashes still decide" {
  conf "$sha256" "$sha1" "file://$dir/www/missing.txt"
  run "$fetch" "$dir/cache"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned hashes only"* ]]
}

@test "the target's pin is complete" {
  unset IRONFLOCKOS_BSP_CONF
  . "$repo/build/lib.sh"
  load_conf "$repo/targets/jetson-orin/bsp.conf"
  [[ "$BSP_SHA256" =~ ^[0-9a-f]{64}$ ]] && [[ "$BSP_SHA1" =~ ^[0-9a-f]{40}$ ]]
  [[ "$BSP_URL" == https://developer.download.nvidia.com/* ]] && [[ "$BSP_HASHES_URL" == https://* ]]
  [[ "$BSP_URL" == *"R$L4T_VERSION"* ]]
}
