#!/usr/bin/env bats
# build/lib.sh check_slot_fill: a root slot's filesystem is checked against
# the warn and fail limits (a slot's size is fixed for a device's lifetime).

repo="$BATS_TEST_DIRNAME/../.."

setup() {
  command -v mke2fs >/dev/null && command -v dumpe2fs >/dev/null || skip "e2fsprogs is not installed"
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  dir=$(mktemp -d)
}

teardown() {
  rm -rf "$dir"
}

# slot SIZE_MIB FILL_MIB: an ext4 of SIZE_MIB holding FILL_MIB of data.
slot() {
  mkdir -p "$dir/tree"
  head -c "$(($2 << 20))" /dev/urandom >"$dir/tree/payload"
  mke2fs -q -t ext4 -m 1 -d "$dir/tree" "$dir/slot.ext4" "${1}M"
}

@test "slot_fill reads the used share from the superblock" {
  slot 64 16
  read -r pct used size <<<"$(slot_fill "$dir/slot.ext4")"
  [ "$size" -eq $((64 << 20)) ]
  [ "$used" -ge $((16 << 20)) ]
  [ "$pct" -ge 25 ] && [ "$pct" -lt 50 ]
}

@test "a slot below the limits passes quietly" {
  slot 64 16
  run check_slot_fill "$dir/slot.ext4" flockos-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"flockos-test: the root slot is "*"% full"* ]]
  [[ "$output" != *"::warning"* ]] && [[ "$output" != *"::error"* ]]
}

# The bands are tested against the slot's own measured fill: ext4's fixed
# overhead (journal, inode tables) differs with the size, so a fill in bytes
# would not land in a band reliably.
@test "a slot past the warning limit warns and annotates the CI run" {
  slot 64 16
  read -r pct _ _ <<<"$(slot_fill "$dir/slot.ext4")"
  FLOCKOS_SLOT_FILL_WARN=$((pct - 1)) FLOCKOS_SLOT_FILL_MAX=$((pct + 10)) run check_slot_fill "$dir/slot.ext4" flockos-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=root slot filling up::flockos-test: the root slot is ${pct}% full"* ]]
  [[ "$output" == *"the build fails from $((pct + 10))%"* ]]
}

@test "a slot at the hard limit fails the build" {
  slot 64 16
  read -r pct _ _ <<<"$(slot_fill "$dir/slot.ext4")"
  FLOCKOS_SLOT_FILL_WARN=$((pct - 5)) FLOCKOS_SLOT_FILL_MAX=$pct run check_slot_fill "$dir/slot.ext4" flockos-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error title=root slot nearly full::flockos-test: the root slot is ${pct}% full"* ]]
  [[ "$output" == *"the limit is ${pct}%"* ]]
}

@test "the defaults warn from 75% and fail from 90%" {
  grep -qF 'warn_at=${FLOCKOS_SLOT_FILL_WARN:-75} max=${FLOCKOS_SLOT_FILL_MAX:-90}' "$repo/build/lib.sh"
}

@test "every image script checks its slot after making it" {
  for s in mkimage.sh mkimage-rpi.sh mkimage-tegra.sh; do
    grep -q '^check_slot_fill "\$rootfs" "\$NAME"$' "$repo/build/$s"
  done
}
