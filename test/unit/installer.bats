#!/usr/bin/env bats
# flockos-installer (WP-3.1): installer.conf, which disks qualify, the
# selection rules, the payload choice, and a dry run of the whole program.

lib="$BATS_TEST_DIRNAME/../../profiles/installer/overlay/usr/lib/flockos"
repo="$BATS_TEST_DIRNAME/../.."

setup() {
  # shellcheck source=profiles/installer/overlay/usr/lib/flockos/installer-lib.sh
  . "$lib/installer-lib.sh"
  tmp=$(mktemp -d)
  # A sealed IPC booted from the installer stick (sdb): one NVMe, one small
  # SATA SSD, a second USB stick, a loop device and a read-only eMMC boot area.
  disks='{"blockdevices": [
    {"name": "sdb", "size": 32000000000, "type": "disk", "tran": "usb", "rm": true, "ro": false, "model": "Flash Disk"},
    {"name": "nvme0n1", "size": 512110190592, "type": "disk", "tran": "nvme", "rm": false, "ro": false, "model": "Samsung SSD 980"},
    {"name": "sda", "size": 64023257088, "type": "disk", "tran": "sata", "rm": false, "ro": false, "model": "SATA SSD"},
    {"name": "sdc", "size": 128000000000, "type": "disk", "tran": "usb", "rm": true, "ro": false, "model": "USB SSD"},
    {"name": "loop0", "size": 100000000000, "type": "loop", "tran": null, "rm": false, "ro": false, "model": null},
    {"name": "mmcblk0boot0", "size": 4194304, "type": "disk", "tran": null, "rm": false, "ro": true, "model": null}
  ]}'
}

teardown() { rm -rf "$tmp"; }

@test "installer.conf: defaults without a file" {
  installer_conf "$tmp/missing"
  [ "$CONF_DISK" = largest ] && [ "$CONF_CONFIRM" = yes ] && [ "$CONF_AFTER" = poweroff ]
  [ "$CONF_ALLOW_USB" = no ] && [ -z "$CONF_PAYLOAD" ]
}

@test "installer.conf: reads every key, tolerates CRLF and comments" {
  printf '# sealed box\r\ndisk = by-id:nvme-Samsung_SSD_980_S1\r\nconfirm=no\r\npayload=nvidia\r\nafter=reboot\r\nallow-usb=yes\r\n' >"$tmp/c"
  installer_conf "$tmp/c"
  [ "$CONF_DISK" = by-id:nvme-Samsung_SSD_980_S1 ]
  [ "$CONF_CONFIRM" = no ] && [ "$CONF_PAYLOAD" = nvidia ] && [ "$CONF_AFTER" = reboot ] && [ "$CONF_ALLOW_USB" = yes ]
}

@test "installer.conf: refuses unknown keys, bad values and anything that is not key=value" {
  for bad in 'disk=/tmp/x' 'disk=$(reboot)' 'confirm=maybe' 'after=halt' 'colour=blue' 'just text'; do
    printf '%s\n' "$bad" >"$tmp/c"
    run installer_conf "$tmp/c"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "candidates: never the stick, USB, loop, read-only or too small" {
  run installer_candidates "$disks" sdb no 10000000000
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1 <<<"$output" | tr '\n' ' ')" = "nvme0n1 sda " ]
}

@test "candidates: USB disks with allow-usb=yes, the stick still never" {
  run installer_candidates "$disks" sdb yes 10000000000
  [[ "$output" == *"sdc "* ]]
  [[ "$output" != *"sdb "* ]]
}

@test "candidates: a disk smaller than the image is left out" {
  run installer_candidates "$disks" sdb no 100000000000
  [ "$(cut -d' ' -f1 <<<"$output")" = nvme0n1 ]
}

@test "select: largest, an explicit disk, a by-id link" {
  c=$(installer_candidates "$disks" sdb no 1)
  [ "$(installer_select largest "$c")" = /dev/nvme0n1 ]
  [ "$(installer_select /dev/sda "$c")" = /dev/sda ]
  mkdir -p "$tmp/by-id" "$tmp/dev"
  ln -s "$tmp/dev/sda" "$tmp/by-id/ata-SATA_SSD_1"
  touch "$tmp/dev/sda"
  run installer_select by-id:ata-SATA_SSD_1 "$c" "$tmp/by-id"
  [ "$status" -eq 0 ]
}

@test "select: refuses the stick, a disk that is not a candidate, and no candidates" {
  c=$(installer_candidates "$disks" sdb no 1)
  run installer_select /dev/sdb "$c"
  [ "$status" -ne 0 ]
  run installer_select /dev/sdz "$c"
  [ "$status" -ne 0 ]
  run installer_select largest ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no disk to install to"* ]]
}

@test "payload: the only one, the one named, and a clear error for several" {
  mkdir -p "$tmp/p"
  touch "$tmp/p/flockos-amd64-efi-base-1.0.0.img.zst"
  [ "$(installer_payload "$tmp/p" "")" = "$tmp/p/flockos-amd64-efi-base-1.0.0.img.zst" ]
  touch "$tmp/p/flockos-amd64-efi-nvidia-1.0.0.img.zst"
  [ "$(installer_payload "$tmp/p" nvidia)" = "$tmp/p/flockos-amd64-efi-nvidia-1.0.0.img.zst" ]
  run installer_payload "$tmp/p" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"set payload="* ]]
}

@test "payload: base never picks base-rt, and an image id selects exactly" {
  mkdir -p "$tmp/p"
  for v in base base-rt nvidia; do touch "$tmp/p/flockos-amd64-efi-$v-1.0.0.img.zst"; done
  [ "$(installer_payload "$tmp/p" base)" = "$tmp/p/flockos-amd64-efi-base-1.0.0.img.zst" ]
  [ "$(installer_payload "$tmp/p" base-rt)" = "$tmp/p/flockos-amd64-efi-base-rt-1.0.0.img.zst" ]
  [ "$(installer_payload "$tmp/p" flockos-amd64-efi-base)" = "$tmp/p/flockos-amd64-efi-base-1.0.0.img.zst" ]
  [ "$(installer_payload "$tmp/p" flockos-amd64-efi-nvidia)" = "$tmp/p/flockos-amd64-efi-nvidia-1.0.0.img.zst" ]
  run installer_payload "$tmp/p" flockos-arm64-efi-base
  [ "$status" -ne 0 ] && [[ "$output" == *"no payload for flockos-arm64-efi-base"* ]]
  run installer_payload "$tmp/p" rt
  [ "$status" -ne 0 ]
}

@test "installer.conf takes an image id as payload, as FlockFlasher writes it" {
  printf 'payload=flockos-amd64-efi-base-rt\n' >"$tmp/installer.conf"
  installer_conf "$tmp/installer.conf"
  [ "$CONF_PAYLOAD" = flockos-amd64-efi-base-rt ]
}

@test "the boot entry's loader is the target's EFI_LOADER" {
  [ "$(installer_loader x86_64)" = '\EFI\BOOT\BOOTX64.EFI' ]
  [ "$(installer_loader aarch64)" = '\EFI\BOOT\BOOTAA64.EFI' ]
  ! installer_loader riscv64
  for t in amd64-efi arm64-efi; do
    want=$(. "$repo/build/lib.sh" && load_conf "$repo/targets/$t/target.conf" && echo "$EFI_LOADER")
    case $t in amd64-efi) m=x86_64 ;; arm64-efi) m=aarch64 ;; esac
    [ "$(installer_loader $m)" = "\\EFI\\BOOT\\$want" ]
  done
}

@test "partition names: sda1, nvme0n1p1, mmcblk0p1" {
  [ "$(installer_partition /dev/sda 1)" = /dev/sda1 ]
  [ "$(installer_partition /dev/nvme0n1 1)" = /dev/nvme0n1p1 ]
  [ "$(installer_partition /dev/mmcblk0 1)" = /dev/mmcblk0p1 ]
}

# A fake machine on PATH for the whole program, in dry-run mode.
fake_machine() {
  mkdir -p "$tmp/bin" "$tmp/esp" "$tmp/payload"
  printf '%s\n' "$disks" >"$tmp/disks.json"
  cat >"$tmp/bin/lsblk" <<SH
#!/bin/bash
case "\$*" in
  *--json*) cat "$tmp/disks.json" ;;
  *PKNAME*) echo sdb ;;
esac
SH
  printf '#!/bin/bash\necho /dev/sdb2\n' >"$tmp/bin/findmnt"
  chmod +x "$tmp/bin"/*
  touch "$tmp/payload/flockos-amd64-efi-base-1.0.0.img.zst"
  echo 4617000000 >"$tmp/payload/flockos-amd64-efi-base-1.0.0.img.zst.size"
  echo '{}' >"$tmp/esp/device.flock"
}

@test "dry run: picks the NVMe, would register it, writes nothing" {
  fake_machine
  printf 'confirm=no\n' >"$tmp/esp/installer.conf"
  PATH="$tmp/bin:$PATH" FLOCKOS_ESP=$tmp/esp FLOCKOS_PAYLOAD_DIR=$tmp/payload FLOCKOS_DRY_RUN=1 run bash "$lib/installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"target: /dev/nvme0n1 (rule: disk=largest)"* ]]
  [[ "$output" == *"would write $tmp/payload/flockos-amd64-efi-base-1.0.0.img.zst to /dev/nvme0n1"* ]]
  [[ "$output" == *"would run: efibootmgr --quiet --create --disk /dev/nvme0n1 --part 1"* ]]
  [[ "$output" == *"would run: systemctl poweroff"* ]]
  grep -q 'target: /dev/nvme0n1' "$tmp/esp/flockos-installer.log"
}

@test "dry run: the .flock and the site's proxy.conf go to the new FLOCKOS partition" {
  fake_machine
  printf 'confirm=no\n' >"$tmp/esp/installer.conf"
  printf 'http_proxy=http://proxy:3128\n' >"$tmp/esp/proxy.conf"
  PATH="$tmp/bin:$PATH" FLOCKOS_ESP=$tmp/esp FLOCKOS_PAYLOAD_DIR=$tmp/payload FLOCKOS_DRY_RUN=1 run bash "$lib/installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copying device.flock to the new FLOCKOS partition"* ]]
  [[ "$output" == *"copying proxy.conf to the new FLOCKOS partition"* ]]
  # The stick keeps it, for the next device.
  [ -e "$tmp/esp/proxy.conf" ]
}

@test "dry run: with confirm=yes anything but 'yes' stops before writing" {
  fake_machine
  PATH="$tmp/bin:$PATH" FLOCKOS_ESP=$tmp/esp FLOCKOS_PAYLOAD_DIR=$tmp/payload FLOCKOS_DRY_RUN=1 run bash "$lib/installer" <<<"no"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stopped on the console"* ]]
  [[ "$output" != *"writing flockos-"* ]]
  [[ "$output" != *"would write"* ]]
}

@test "dry run: an invalid installer.conf stops with the reason" {
  fake_machine
  printf 'disk=/tmp/evil\n' >"$tmp/esp/installer.conf"
  PATH="$tmp/bin:$PATH" FLOCKOS_ESP=$tmp/esp FLOCKOS_PAYLOAD_DIR=$tmp/payload FLOCKOS_DRY_RUN=1 run bash "$lib/installer"
  [ "$status" -ne 0 ]
  [[ "$output" == *"installer.conf:1"* ]]
}
