#!/usr/bin/env bats
# build/lib.sh: configuration parsing, templates, sizes, the matrix axes.

setup() {
  # shellcheck source=build/lib.sh
  . "$BATS_TEST_DIRNAME/../../build/lib.sh"
  tmp=$(mktemp -d)
}

teardown() { rm -rf "$tmp"; }

@test "load_conf exports KEY=value lines and strips quotes" {
  printf '%s\n' '# comment' '' 'A=1' 'B="two words"' "C='three'" >"$tmp/c"
  load_conf "$tmp/c"
  [ "$A" = 1 ]
  [ "$B" = "two words" ]
  [ "$C" = three ]
}

@test "load_conf refuses anything but assignments" {
  printf '%s\n' 'A=1' 'echo pwned' >"$tmp/c"
  run load_conf "$tmp/c"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* || "$output" == *":2:"* ]]
}

@test "load_conf does not run command substitutions" {
  printf '%s\n' 'A=$(touch '"$tmp"'/ran)' >"$tmp/c"
  load_conf "$tmp/c"
  [ ! -e "$tmp/ran" ]
  [ "$A" = "\$(touch $tmp/ran)" ]
}

@test "render fills @VAR@ and fails on a hole" {
  printf 'a=@ALPHA@ b=@BETA@\n' >"$tmp/t"
  ALPHA=1 BETA=2 run render "$tmp/t"
  [ "$status" -eq 0 ]
  [ "$output" = "a=1 b=2" ]
  unset BETA
  ALPHA=1 run render "$tmp/t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"@BETA@"* ]]
}

@test "size_bytes understands K, M, G and bytes" {
  [ "$(size_bytes 512K)" = 524288 ]
  [ "$(size_bytes 256M)" = 268435456 ]
  [ "$(size_bytes 4G)" = 4294967296 ]
  [ "$(size_bytes 1000)" = 1000 ]
  run size_bytes 4T
  [ "$status" -ne 0 ]
}

@test "image_id names the RAUC compatible" {
  [ "$(image_id amd64-efi base std)" = flockos-amd64-efi-base ]
  [ "$(image_id rpi-arm64 base rt)" = flockos-rpi-arm64-base-rt ]
}

@test "the matrix axes reject unknown names" {
  valid_target amd64-efi
  valid_variant nvidia
  valid_kernel rt
  ! valid_target x86
  ! valid_variant desktop
  ! valid_kernel lowlatency
}

@test "read_list drops comments and blank lines and skips missing files" {
  printf '%s\n' '# c' 'a' '' 'b # trailing' >"$tmp/l"
  run read_list "$tmp/l" "$tmp/missing"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a\nb')" ]
}
