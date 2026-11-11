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
  [ "$(image_id amd64-efi base std)" = ironflockos-amd64-efi-base ]
  [ "$(image_id rpi-arm64 base rt)" = ironflockos-rpi-arm64-base-rt ]
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

@test "uuid_for derives a version-4 UUID from the image id and a name" {
  IMAGE_ID=ironflockos-amd64-efi-base
  a=$(uuid_for rootfs-a)
  [ "$a" = "$(uuid_for rootfs-a)" ]
  [ "$a" != "$(uuid_for rootfs-b)" ]
  [[ "$a" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$ ]]
  IMAGE_ID=ironflockos-rpi-arm64-base
  [ "$a" != "$(uuid_for rootfs-a)" ]
}

# repart TARGET VARIANT: the target's repart.d rendered as the image has it
# (build/customize.sh), in $tmp/repart.d.
repart() {
  rm -rf "$tmp/repart.d"
  mkdir -p "$tmp/repart.d"
  (
    load_conf "$BATS_TEST_DIRNAME/../../targets/$1/target.conf"
    var=SLOT_SIZE_$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
    export SLOT_SIZE=${!var}
    for f in "$BATS_TEST_DIRNAME/../../targets/$1"/repart.d/*.conf; do
      render "$f" >"$tmp/repart.d/$(basename "$f")"
    done
  )
}

@test "min_disk_size: every partition of the device's layout at its least, 1 GiB of /data and 2 MiB for the GPT" {
  gib=$((1 << 30)) mib=$((1 << 20))
  # amd64-efi base: IRONFLOCKOS, two 4 GiB slots (v0.14.0's image is 4564471808 bytes raw).
  repart amd64-efi base
  [ "$(min_disk_size "$tmp/repart.d" 4564471808)" = $((2 * mib + 256 * mib + 8 * gib + gib)) ]
  repart arm64-efi base
  [ "$(min_disk_size "$tmp/repart.d" 4564471808)" = $((2 * mib + 256 * mib + 8 * gib + gib)) ]
  # nvidia: two 8 GiB slots.
  repart amd64-efi nvidia
  [ "$(min_disk_size "$tmp/repart.d" 8859439104)" = $((2 * mib + 256 * mib + 16 * gib + gib)) ]
  # The Raspberry Pi: IRONFLOCKOS, boot-a and boot-b besides the slots.
  repart rpi-arm64 base
  [ "$(min_disk_size "$tmp/repart.d" 4900016128)" = $((2 * mib + 64 * mib + 512 * mib + 8 * gib + gib)) ]
}

@test "min_disk_size: the raw size for the installer (no repart.d given), and never less than it" {
  [ "$(min_disk_size "" 5638213632)" = 5638213632 ]
  repart amd64-efi base
  [ "$(min_disk_size "$tmp/repart.d" 99999999999)" = 99999999999 ]
}

@test "min_disk_size: a device image whose repart.d is missing or empty stops the build" {
  mkdir "$tmp/empty"
  for dir in "$tmp/empty" "$tmp/missing"; do
    run min_disk_size "$dir" 4564471808
    [ "$status" -ne 0 ]
    [[ "$output" == *"$dir has no repart.d definitions"* ]]
    run write_sizes "$BATS_TEST_FILENAME" "$dir" "$tmp/x.sizes"
    [ "$status" -ne 0 ]
  done
}

@test "min_disk_size: one partition, /data, takes the rest of the disk" {
  repart amd64-efi base
  sed -i.bak '/^SizeMinBytes=/d' "$tmp/repart.d/30-rootfs-b.conf"
  rm -f "$tmp/repart.d"/*.bak
  run min_disk_size "$tmp/repart.d" 4564471808
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 partitions without SizeMinBytes"* ]]
}

@test "the Compute Engine images get the same disk, rounded up to whole GiB (ADR-0008 of device-init: 10 and 18 GiB)" {
  load_conf "$BATS_TEST_DIRNAME/../../build/release.conf"
  [ "$GCE_DATA_MIN" = 1G ]
  gib=$((1 << 30))
  repart amd64-efi base
  min=$(min_disk_size "$tmp/repart.d" 4564471808)
  [ $(((min + gib - 1) / gib)) = 10 ]
  repart amd64-efi nvidia
  min=$(min_disk_size "$tmp/repart.d" 8859439104)
  [ $(((min + gib - 1) / gib)) = 18 ]
}

@test "write_sizes records raw_size and min_disk_size for the catalog" {
  head -c 3000 /dev/zero >"$tmp/disk.img"
  repart amd64-efi base
  run write_sizes "$tmp/disk.img" "$tmp/repart.d" "$tmp/x.sizes"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/x.sizes")" = "$(printf 'raw_size=3000\nmin_disk_size=%s' $(((2 + 256) * (1 << 20) + 9 * (1 << 30))))" ]
  write_sizes "$tmp/disk.img" "" "$tmp/y.sizes"
  [ "$(cat "$tmp/y.sizes")" = "$(printf 'raw_size=3000\nmin_disk_size=3000')" ]
}

# kernel ROOT VERSION: a kernel's module lists as a 6.12 kernel package and
# depmod leave them: modules.alias (depmod); modules.builtin.modinfo
# (NUL-separated <module>.<key>=<value> records), which holds only the
# aliases a built-in driver declares by name, not its device table's: no
# line for virtio_pci or nvme; modules.builtin, the built-in drivers' paths.
kernel() {
  local d=$1/usr/lib/modules/$2
  mkdir -p "$d"
  printf '# Aliases extracted from modules themselves.\nalias pci:v00008086d000015B8sv*sd*bc*sc*i* e1000e\nalias virtio:d00000001v* virtio_net\n' >"$d/modules.alias"
  printf 'nvme.license=GPL\0nvme.description=NVM Express device driver\0ext4.alias=fs-ext4\0ext4.description=Fourth Extended Filesystem\0virtio_pci.license=GPL\0' >"$d/modules.builtin.modinfo"
  printf 'kernel/fs/ext4/ext4.ko\nkernel/drivers/virtio/virtio_pci.ko\nkernel/drivers/nvme/host/nvme.ko\n' >"$d/modules.builtin"
}

@test "hardware_list: each kernel's alias lines, then a builtin line per built-in driver, under a comment line" {
  kernel "$tmp/root" 6.12.48+deb13-amd64
  run hardware_list "$tmp/root" 6.12.48+deb13-amd64
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    '# kernel 6.12.48+deb13-amd64: alias lines of modules.alias and modules.builtin.modinfo, builtin lines of modules.builtin' \
    'alias pci:v00008086d000015B8sv*sd*bc*sc*i* e1000e' 'alias virtio:d00000001v* virtio_net' \
    'alias fs-ext4 ext4' 'builtin ext4' 'builtin virtio_pci' 'builtin nvme')" ]
  # The Raspberry Pi's two kernels.
  kernel "$tmp/root" 6.12.47+rpt-rpi-2712
  run hardware_list "$tmp/root" 6.12.48+deb13-amd64 6.12.47+rpt-rpi-2712
  [ "$(grep -c '^# kernel ' <<<"$output")" = 2 ]
  [ "$(grep -c '^alias ' <<<"$output")" = 6 ]
  [ "$(grep -c '^builtin ' <<<"$output")" = 6 ]
}

@test "hardware_list: a kernel without modules.alias, modules.builtin.modinfo or modules.builtin stops the build" {
  run hardware_list "$tmp/root" 6.12.48+deb13-amd64
  [ "$status" -ne 0 ]
  [[ "$output" == *"kernel 6.12.48+deb13-amd64 has no modules.alias"* ]]
  kernel "$tmp/root" 6.12.48+deb13-amd64
  rm "$tmp/root/usr/lib/modules/6.12.48+deb13-amd64/modules.builtin.modinfo"
  # depmod writes the built-in aliases only as modules.builtin.alias.bin.
  printf 'alias pci:v*d*sv*sd*bc01sc08i02* nvme\n' >"$tmp/root/usr/lib/modules/6.12.48+deb13-amd64/modules.builtin.alias"
  run hardware_list "$tmp/root" 6.12.48+deb13-amd64
  [ "$status" -ne 0 ]
  [[ "$output" == *"kernel 6.12.48+deb13-amd64 has no modules.builtin.modinfo"* ]]
  kernel "$tmp/root" 6.12.48+deb13-amd64
  rm "$tmp/root/usr/lib/modules/6.12.48+deb13-amd64/modules.builtin"
  run hardware_list "$tmp/root" 6.12.48+deb13-amd64
  [ "$status" -ne 0 ]
  [[ "$output" == *"kernel 6.12.48+deb13-amd64 has no modules.builtin in"* ]]
}

@test "the build publishes each disk image's hardware list, gzip without a name or time" {
  grep -qx '  hardware_list "$ROOT" "${kernel_versions\[@\]}" | gzip -9n >"$OUT/$NAME.modules.alias.gz"' \
    "$BATS_TEST_DIRNAME/../../build/customize.sh"
  grep -qx 'if \[ "$BOOTLOADER" != tegra \]; then' "$BATS_TEST_DIRNAME/../../build/customize.sh"
  grep -q "\-o -name '\*.modules.alias.gz'" "$BATS_TEST_DIRNAME/../../build/publish.sh"
}
