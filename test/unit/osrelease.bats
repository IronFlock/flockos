#!/usr/bin/env bats
# build/osrelease.sh: the /etc/os-release contract (master plan, section 3.1).

osr="$BATS_TEST_DIRNAME/../../build/osrelease.sh"

@test "carries the fields the agent, device-init and the platform read" {
  run bash "$osr" 1.2.3 amd64-efi base std 1a2b3c4d5e6f7a8b 1793000000
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nID=flockos\n'* ]]
  [[ "$output" == *$'\nID_LIKE=debian\n'* ]]
  [[ "$output" == *$'\nIMAGE_ID=flockos-amd64-efi-base\n'* ]]
  [[ "$output" == *$'\nIMAGE_VERSION=1.2.3\n'* ]]
  [[ "$output" == *$'\nVERSION_ID="1.2.3"\n'* ]]
  [[ "$output" == *$'\nBUILD_ID=20261026T073320Z-g1a2b3c4\n'* ]]
}

@test "VERSION keeps the legacy v<ver>-g<sha>-<buildtime> shape (three dash parts)" {
  run bash "$osr" 1.2.3 amd64-efi base std 1a2b3c4d5e6f 1793000000
  line=$(printf '%s\n' "$output" | sed -n 's/^VERSION="\(.*\)"$/\1/p')
  [ "$line" = "v1.2.3-g1a2b3c4-20261026T073320" ]
  IFS=- read -ra parts <<<"$line"
  [ "${#parts[@]}" -eq 3 ]
}

@test "an rt image says so in IMAGE_ID and PRETTY_NAME" {
  run bash "$osr" 1.0.0 rpi-arm64 base rt abcdef1 1793000000
  [ "$status" -eq 0 ]
  [[ "$output" == *"IMAGE_ID=flockos-rpi-arm64-base-rt"* ]]
  [[ "$output" == *'PRETTY_NAME="IronFlockOS 1.0.0 (rpi-arm64, base, rt)"'* ]]
}

@test "rejects malformed input" {
  run bash "$osr" 1.2 amd64-efi base std abcdef1 1793000000
  [ "$status" -ne 0 ]
  run bash "$osr" 1.2.3 amd64 base std abcdef1 1793000000
  [ "$status" -ne 0 ]
  run bash "$osr" 1.2.3 amd64-efi base std not-a-sha 1793000000
  [ "$status" -ne 0 ]
}
