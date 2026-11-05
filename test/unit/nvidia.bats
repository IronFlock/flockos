#!/usr/bin/env bats
# The nvidia profile (WP-4.1): pinned versions, NVIDIA's keys, and the units
# that must stay inert on a host without a GPU.

repo="$BATS_TEST_DIRNAME/../.."
profile="$repo/profiles/nvidia"

setup() {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$profile/versions"
}

@test "versions are pinned Debian versions and mirrors are https" {
  [[ "$NVIDIA_DRIVER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
  [[ "$NVIDIA_CONTAINER_TOOLKIT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
  [[ "$NVIDIA_CUDA_MIRROR" == https://* ]]
  [[ "$NVIDIA_CTK_MIRROR" == https://* ]]
}

@test "every package build/mkrootfs.sh pins is in the package list" {
  mapfile -t listed < <(read_list "$profile/packages")
  pinned=$(sed -n 's/^  for p in \(.*\); do$/\1/p' "$repo/build/mkrootfs.sh" | tr ' ' '\n')
  [ -n "$pinned" ]
  for p in $pinned; do
    printf '%s\n' "${listed[@]}" | grep -qx "$p"
  done
}

@test "NVIDIA's keys are the pinned ones" {
  command -v gpg >/dev/null || skip "gpg is not installed"
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  for pair in "cuda.asc $NVIDIA_CUDA_SIGNER_FINGERPRINT" "nvidia-container-toolkit.asc $NVIDIA_CTK_SIGNER_FINGERPRINT"; do
    set -- $pair
    head -n 1 "$profile/apt/$1" | grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----'
    fpr=$(gpg --show-keys --with-colons "$profile/apt/$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    [ "$fpr" = "$2" ]
  done
  rm -rf "$GNUPGHOME"
}

@test "the preset sorts before NVIDIA's and keeps the GPU services off at boot" {
  preset=$(ls "$profile/overlay/usr/lib/systemd/system-preset")
  [[ "$preset" < "70-nvidia-driver.preset" ]]
  grep -qx 'disable nvidia-persistenced.service' "$profile/overlay/usr/lib/systemd/system-preset/$preset"
  grep -qx 'disable nvidia-powerd.service' "$profile/overlay/usr/lib/systemd/system-preset/$preset"
}

@test "udev starts nvidia-persistenced when the nvidia module loads" {
  rule=$(grep -v '^#' "$profile/overlay/usr/lib/udev/rules.d/71-flockos-nvidia.rules")
  [[ "$rule" == *'SUBSYSTEM=="module", KERNEL=="nvidia"'* ]]
  [[ "$rule" == *'ENV{SYSTEMD_WANTS}+="nvidia-persistenced.service"'* ]]
}

@test "nvidia-modules.sh wants the driver version" {
  run bash "$repo/build/nvidia-modules.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: nvidia-modules.sh DRIVER_VERSION"* ]]
}
