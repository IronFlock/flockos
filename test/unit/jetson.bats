#!/usr/bin/env bats
# The jetson-orin target's root tree (WP-6.2; ADR-0008): its distribution,
# NVIDIA's repositories and key, the pins, the RAUC slots, and what the
# build refuses until the layout exists.

repo="$BATS_TEST_DIRNAME/../.."
t="$repo/targets/jetson-orin"

setup() {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$t/target.conf"
}

@test "jetson-orin is arm64 on Ubuntu 24.04 with NVIDIA's boot chain" {
  [ "$ARCH" = arm64 ] && [ "$DISTRO" = ubuntu-noble ] && [ "$BOOTLOADER" = tegra ]
  [ -f "$repo/distros/$DISTRO/versions" ]
  [ -n "$SLOT_SIZE_BASE" ] && size_bytes "$SLOT_SIZE_BASE" >/dev/null
  [[ "$CONSOLE_CMDLINE" == *console=ttyTCU0,115200* ]]
}

@test "NVIDIA's apt key is the pinned one" {
  command -v gpg >/dev/null || skip "gpg is not installed"
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  fpr=$(gpg --show-keys --with-colons "$t/apt/jetson-ota-public.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  rm -rf "$GNUPGHOME"
  [ "$fpr" = "$L4T_SIGNER_FINGERPRINT" ]
}

@test "the L4T pins belong to the BSP's release" {
  load_conf "$t/bsp.conf"
  [[ "$L4T_PACKAGE_VERSION" == "$L4T_VERSION-"* ]]
  [[ "$L4T_KERNEL_VERSION" == *"-tegra-$L4T_PACKAGE_VERSION" ]]
  [ "$L4T_SUITE" = "r${L4T_VERSION%.*}" ]
  [[ "$L4T_MIRROR" == https://* ]]
  [[ "$L4T_CONTAINER_TOOLKIT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
}

@test "the package list is Orin's L4T flavour, without what the build replaces" {
  mapfile -t pkgs < <(read_list "$t/packages")
  for p in nvidia-l4t-core nvidia-l4t-kernel nvidia-l4t-kernel-nvgpu nvidia-l4t-kernel-oot-modules \
    nvidia-l4t-initrd nvidia-l4t-cuda-nvgpu nvidia-l4t-bootloader-utils nvidia-container-toolkit; do
    printf '%s\n' "${pkgs[@]}" | grep -qx "$p"
  done
  ! printf '%s\n' "${pkgs[@]}" | grep -qE -- '-openrm$|^nvidia-l4t-(bootloader|extlinux|apt-source|configs)$|^linux-image-'
}

@test "mkrootfs pins every listed L4T package and keeps NVIDIA's archive below Ubuntu" {
  f=$repo/build/mkrootfs.sh
  grep -q 'pin "$name" "$L4T_KERNEL_VERSION"' "$f"
  grep -q 'pin "$name" "$L4T_PACKAGE_VERSION"' "$f"
  grep -q 'pin "$name" "$L4T_CONTAINER_TOOLKIT_VERSION"' "$f"
  grep -q 'Pin: origin %s\\nPin-Priority: 100' "$f"
  grep -q 'nv-l4t-disable-boot-fw-update-in-preinstall' "$f"
}

@test "RAUC: the custom backend over APP and APP_b" {
  run bash -c ". '$repo/build/lib.sh'; COMPATIBLE=ironflockos-jetson-orin-base render '$t/system.conf'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'compatible=ironflockos-jetson-orin-base'
  printf '%s\n' "$output" | grep -qx 'bootloader=custom'
  printf '%s\n' "$output" | grep -A1 '^\[slot.rootfs.0\]' | grep -qx 'device=/dev/disk/by-partlabel/APP'
  printf '%s\n' "$output" | grep -A1 '^\[slot.rootfs.1\]' | grep -qx 'device=/dev/disk/by-partlabel/APP_b'
  [ ! -d "$t/repart.d" ]
}

@test "the build makes jetson-orin in the base variant with the standard kernel only" {
  export IRONFLOCKOS_VERSION=0.0.0 IRONFLOCKOS_COMMIT=0 SOURCE_DATE_EPOCH=0
  IRONFLOCKOS_STAGES=rootfs run bash "$repo/build/build.sh" jetson-orin nvidia std
  [ "$status" -ne 0 ] && [[ "$output" == *"jetson-orin is built in the base variant only"* ]]
  IRONFLOCKOS_STAGES=rootfs run bash "$repo/build/build.sh" jetson-orin base rt
  [ "$status" -ne 0 ] && [[ "$output" == *"the rt kernel is built for the EFI targets only"* ]]
}

@test "slot A's extlinux.conf: NVIDIA's kernel, initrd and command line, root= and rauc.slot= of the slot" {
  run bash -c ". '$repo/build/lib.sh'; load_conf '$t/target.conf'; SLOT=A ROOT_PARTUUID=029565df-068d-4b3e-8d32-fc21d85f7d1e render '$t/boot/extlinux.conf'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"@"*"@"* ]]
  printf '%s\n' "$output" | grep -qx 'DEFAULT ironflockos'
  printf '%s\n' "$output" | grep -qE '^[[:space:]]+LINUX /boot/Image$'
  printf '%s\n' "$output" | grep -qE '^[[:space:]]+INITRD /boot/initrd$'
  append=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*APPEND //p')
  [[ "$append" == '${cbootargs} root=PARTUUID=029565df-068d-4b3e-8d32-fc21d85f7d1e rw rootwait rootfstype=ext4 '* ]]
  [[ " $append " == *" console=ttyTCU0,115200 "* ]] && [[ " $append " == *" rauc.slot=A "* ]]
  [[ " $append " == *" firmware_class.path=/etc/firmware "* ]]
  [[ " $append " == *" panic=10 "* ]]
}

extlinux_tool="$repo/targets/jetson-orin/overlay/usr/lib/ironflockos/tegra-extlinux"

@test "tegra-extlinux points the bundle's extlinux.conf at slot B" {
  dir=$(mktemp -d)
  printf '# a comment with root=x\nDEFAULT ironflockos\nLABEL ironflockos\n\tLINUX /boot/Image\n\tAPPEND ${cbootargs} root=PARTUUID=029565df-068d-4b3e-8d32-fc21d85f7d1e rw rootwait console=ttyTCU0,115200 rauc.slot=A\n' >"$dir/extlinux.conf"
  run "$extlinux_tool" "$dir/extlinux.conf" 5c0ffee0-1234-4abc-8def-0123456789ab B
  [ "$status" -eq 0 ]
  grep -qx $'\tAPPEND ${cbootargs} root=PARTUUID=5c0ffee0-1234-4abc-8def-0123456789ab rw rootwait console=ttyTCU0,115200 rauc.slot=B' "$dir/extlinux.conf"
  grep -qx '# a comment with root=x' "$dir/extlinux.conf"
  [ "$(wc -l <"$dir/extlinux.conf")" -eq 5 ] && [ ! -e "$dir/extlinux.conf.new" ]
  rm -rf "$dir"
}

@test "tegra-extlinux refuses what it cannot rewrite" {
  dir=$(mktemp -d)
  printf 'LABEL x\n\tAPPEND ${cbootargs} rootwait\n' >"$dir/extlinux.conf"
  run "$extlinux_tool" "$dir/extlinux.conf" 5c0ffee0 B
  [ "$status" -ne 0 ] && [[ "$output" == *"no APPEND line with root="* ]]
  printf 'LABEL x\n\tAPPEND root=PARTUUID=x rauc.slot=A\n' >"$dir/extlinux.conf"
  run "$extlinux_tool" "$dir/extlinux.conf" 'x/y' B
  [ "$status" -ne 0 ]
  run "$extlinux_tool" "$dir/extlinux.conf" 5c0ffee0 C
  [ "$status" -ne 0 ]
  run "$extlinux_tool" "$dir/missing.conf" 5c0ffee0 B
  [ "$status" -ne 0 ]
  grep -qx $'\tAPPEND root=PARTUUID=x rauc.slot=A' "$dir/extlinux.conf"
  rm -rf "$dir"
}

layout_tool="$repo/build/tegra-layout.py"

# A layout shaped like the BSP's NVMe rootfs A/B layout (the real one is
# NVIDIA's, read from the BSP at build time): only what the tool checks.
fixture_layout() {
  cat <<'XML'
<?xml version="1.0"?>
<!-- a fixture, not NVIDIA's layout -->
<partition_layout version="01.00.0000">
    <device type="external" instance="0" sector_size="512" num_sectors="EXT_NUM_SECTORS" >
        <partition name="primary_gpt" type="primary_gpt">
            <size> 19968 </size>
        </partition>
        <partition name="A_kernel" id="3" type="kernel">
            <size> 134217728 </size>
        </partition>
        <partition name="esp" type="data">
            <size> 67108864 </size>
            <filename> ESP_FILE </filename>
            <partition_type_guid> C12A7328-F81F-11D2-BA4B-00A0C93EC93B </partition_type_guid>
        </partition>
        <partition name="APP" id="1" type="data">
            <size> APPSIZE </size>
            <filename> APPFILE </filename>
        </partition>
        <partition name="APP_b" id="2" type="data">
            <size> APPSIZE </size>
            <filename> APPFILE_b </filename>
        </partition>
        <partition name="secondary_gpt" type="secondary_gpt">
            <size> 0xFFFFFFFFFFFFFFFF </size>
        </partition>
    </device>
</partition_layout>
XML
}

@test "tegra-layout adds /data after APP_b, grown to the end, with a GPT number of its own" {
  dir=$(mktemp -d)
  fixture_layout >"$dir/in.xml"
  run python3 -I "$layout_tool" "$dir/in.xml" "$dir/out.xml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, xml.etree.ElementTree as ET
dev = ET.parse(sys.argv[1]).getroot().find("device")
parts = dev.findall("partition")
print(" ".join(p.get("name") for p in parts))
d = [p for p in parts if p.get("name") == "data"][0]
print(d.find("allocation_attribute").text.strip(), d.find("partition_type_guid").text.strip(), d.get("id"))
app_b = [p for p in parts if p.get("name") == "APP_b"][0]
print(app_b.find("size").text.strip(), app_b.get("id"))
' "$dir/out.xml"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "primary_gpt A_kernel esp APP APP_b data secondary_gpt" ]
  # A_kernel 3, esp 4 (counted on), APP 1, APP_b 2: data takes 5, not 3
  [ "${lines[1]}" = "0x808 0FC63DAF-8483-4772-8E79-3D69D8477DE4 5" ]
  [ "${lines[2]}" = "APPSIZE 2" ]
  head -n 2 "$dir/out.xml" | grep -qx '<!-- a fixture, not NVIDIA.s layout -->'
  rm -rf "$dir"
}

@test "tegra-layout refuses a layout that is not shaped as expected" {
  dir=$(mktemp -d)
  fixture_layout | sed '/name="APP_b"/,/<\/partition>/d' >"$dir/no-b.xml"
  run python3 -I "$layout_tool" "$dir/no-b.xml" "$dir/out.xml"
  [ "$status" -ne 0 ] && [[ "$output" == *"no APP_b partition"* ]]
  fixture_layout | sed 's/name="APP_b"/name="data"/' >"$dir/data.xml"
  run python3 -I "$layout_tool" "$dir/data.xml" "$dir/out.xml"
  [ "$status" -ne 0 ] && [[ "$output" == *"already has a partition named data"* ]]
  fixture_layout | sed 's/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/0FC63DAF-8483-4772-8E79-3D69D8477DE4/' >"$dir/esp.xml"
  run python3 -I "$layout_tool" "$dir/esp.xml" "$dir/out.xml"
  [ "$status" -ne 0 ] && [[ "$output" == *"esp is not an EFI system partition"* ]]
  fixture_layout | sed '0,/APPSIZE/s/APPSIZE/8589934592/' >"$dir/size.xml"
  run python3 -I "$layout_tool" "$dir/size.xml" "$dir/out.xml"
  [ "$status" -ne 0 ] && [[ "$output" == *"APP's size is not the APPSIZE placeholder"* ]]
  fixture_layout | sed 's/ id="3"//' >"$dir/dup.xml"
  run python3 -I "$layout_tool" "$dir/dup.xml" "$dir/out.xml"
  [ "$status" -ne 0 ] && [[ "$output" == *"GPT entry numbers used twice"* ]]
  printf 'not xml' >"$dir/bad.xml"
  run python3 -I "$layout_tool" "$dir/bad.xml" "$dir/out.xml"
  [ "$status" -ne 0 ]
  [ ! -e "$dir/out.xml" ]
  rm -rf "$dir"
}

@test "the Jetson image is slot A's filesystem, and the ESP is /boot/efi" {
  grep -q 'tegra) bash "$here/mkimage-tegra.sh"' "$repo/build/build.sh"
  grep -q 'files=(\*.rootfs.ext4.zst)' "$repo/build/build.sh"
  grep -q 's|^PARTLABEL=IRONFLOCKOS  /boot/efi |PARTLABEL=esp          /boot/efi |' "$repo/build/customize.sh"
  grep -q '^PARTLABEL=IRONFLOCKOS  /boot/efi ' "$repo/overlay/etc/fstab"
}

@test "tegra-flash-package checks its arguments before it touches anything" {
  run bash "$repo/build/tegra-flash-package.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"usage: tegra-flash-package.sh L4T_DIR SLOT_IMAGE BOARD BOARDID BOARDSKU"* ]]
  if [ "$(id -u)" != 0 ]; then
    run bash "$repo/build/tegra-flash-package.sh" "$BATS_TEST_TMPDIR" x.rootfs.ext4.zst jetson-orin-nano-devkit 3767 0003
    [ "$status" -ne 0 ] && [[ "$output" == *"needs root"* ]]
  fi
  # NVIDIA's -r fix knows the BSP's exact getopts strings
  grep -q 'fix_reuse_option l4t_initrd_flash.func "u:p:P:v:c:r:-:S:k:i:" "u:p:P:v:c:r-:S:k:i:"' "$repo/build/tegra-flash-package.sh"
  grep -q 'fix_reuse_option l4t_create_images_for_kernel_flash.sh "k:u:p:v:c:r:-:S:i:" "k:u:p:v:c:r-:S:i:"' "$repo/build/tegra-flash-package.sh"
}
