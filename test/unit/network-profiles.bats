#!/usr/bin/env bats
# Network profiles from the FLOCKOS partition (ADR-0016, docs/build.md
# "Network profiles"): NetworkManager keyfiles there, network/*.nmconnection,
# become the device's profiles on /data before NetworkManager starts; refused
# ones are renamed; a pending factory reset holds them back.

repo="$BATS_TEST_DIRNAME/../.."
script="$repo/overlay/usr/lib/flockos/network-profiles"
units="$repo/overlay/usr/lib/systemd/system"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/esp/network" "$tmp/data/network/connections"
  # shred as the device has it, with a record of what it overwrote.
  printf '#!/bin/sh\necho "$*" >>"%s/shred.log"\n[ "$1" = -u ] && rm -f "$2"\n' "$tmp" >"$tmp/bin/shred"
  # sync FILE... as coreutils has it (fsync of those files), recorded; with
  # sync.kill holding N, the Nth call stops the script as a power loss or the
  # unit's time limit would.
  printf '#!/bin/sh\necho "$*" >>"%s/sync.log"\nn=$(wc -l <"%s/sync.log")\nif [ -f "%s/sync.kill" ] && [ "$n" -eq "$(cat "%s/sync.kill")" ]; then kill -9 "$PPID"; fi\nexit 0\n' \
    "$tmp" "$tmp" "$tmp" "$tmp" >"$tmp/bin/sync"
  chmod +x "$tmp/bin/shred" "$tmp/bin/sync"
  export PATH="$tmp/bin:$PATH" FLOCKOS_ESP=$tmp/esp FLOCKOS_CONNECTIONS=$tmp/data/network/connections
  src=$tmp/esp/network dest=$tmp/data/network/connections
}

teardown() {
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# static NAME [UUID]: a profile for a static address on a card matched by its
# MAC address, as `ironflock os install` writes one.
static() {
  printf '[connection]\nid=%s\nuuid=%s\ntype=ethernet\nautoconnect-priority=10\n\n[ethernet]\nmac-address=52:54:00:12:34:56\n\n[ipv4]\nmethod=manual\naddress1=192.168.10.20/24\ngateway=192.168.10.1\ndns=192.168.10.1;\n\n[ipv6]\nmethod=disabled\n' \
    "${1%.nmconnection}" "${2:-6f1b1f8e-4a52-4f3e-9d0b-5a1c2e3d4f50}"
}

wifi='[connection]
id=Factory WiFi
type=wifi

[wifi]
mode=infrastructure
ssid=Factory WiFi

[wifi-security]
key-mgmt=wpa-psk
psk=s3cret pass

[ipv4]
method=auto
'

@test "without a profile on the FLOCKOS partition nothing changes" {
  rmdir "$src"
  run bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no profile on the FLOCKOS partition"* ]]
  [ -z "$(ls -A "$dest")" ]
}

@test "a static profile moves to /data, readable by root only, and leaves the partition overwritten" {
  static office.nmconnection >"$src/office.nmconnection"
  static office.nmconnection >"$tmp/want"
  run bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"took office.nmconnection (ethernet) from the FLOCKOS partition"* ]]
  cmp "$tmp/want" "$dest/office.nmconnection"
  [ "$(mode "$dest/office.nmconnection")" = 600 ]
  [ ! -e "$src/office.nmconnection" ]
  # The folder goes once it is empty.
  [ ! -e "$src" ]
  [ "$(cat "$tmp/shred.log")" = "-u $src/office.nmconnection" ]
  [ -z "$(ls -A "$dest" | grep -v '^office.nmconnection$')" ]
}

@test "a Wi-Fi profile with CRLF line ends and a byte order mark is written with LF and without it; the password stays out of the log" {
  printf '\xef\xbb\xbf%s' "${wifi//$'\n'/$'\r\n'}" >"$src/factory-wifi.nmconnection"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ "$(cat "$dest/factory-wifi.nmconnection")" = "$(printf '%s' "$wifi")" ]
  ! grep -q $'\r' "$dest/factory-wifi.nmconnection"
  [ "$(head -c 12 "$dest/factory-wifi.nmconnection")" = "[connection]" ]
  [[ "$output" != *"s3cret"* ]]
  [ ! -e "$src/factory-wifi.nmconnection" ]
}

@test "a profile replaces the device's of the same name and any other with the same uuid; the rest stays" {
  printf '[connection]\nid=old\ntype=ethernet\n' >"$dest/office.nmconnection"
  # The same uuid in capitals, under another name: NetworkManager keeps one.
  static old-name.nmconnection 6F1B1F8E-4A52-4F3E-9D0B-5A1C2E3D4F50 >"$dest/old-name.nmconnection"
  static other.nmconnection 11111111-2222-4333-8444-555555555555 >"$dest/other.nmconnection"
  printf '%s' "$wifi" >"$dest/ironflock-wifi.nmconnection"
  printf 'not a keyfile\n' >"$dest/notes"
  static office.nmconnection >"$src/office.nmconnection"
  run bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"office.nmconnection replaces the device's profile of that name"* ]]
  [[ "$output" == *"office.nmconnection replaces old-name.nmconnection, which has the same uuid"* ]]
  grep -qx 'id=office' "$dest/office.nmconnection"
  [ ! -e "$dest/old-name.nmconnection" ]
  [ -e "$dest/other.nmconnection" ]
  [ -e "$dest/ironflock-wifi.nmconnection" ]
  [ -e "$dest/notes" ]
}

@test "several profiles are taken in one boot" {
  static a.nmconnection 11111111-2222-4333-8444-555555555555 >"$src/a.nmconnection"
  printf '%s' "$wifi" >"$src/b_wifi-2.nmconnection"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ -e "$dest/a.nmconnection" ]
  [ -e "$dest/b_wifi-2.nmconnection" ]
  [ ! -e "$src" ]
}

@test "check: exit 0 for a profile it takes, the reason without the file's name for one it refuses, exit 2 for wrong arguments" {
  static office.nmconnection >"$tmp/office.nmconnection"
  run bash "$script" check "$tmp/office.nmconnection"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf '[connection]\nid=x\n' >"$tmp/office.nmconnection"
  run bash "$script" check "$tmp/office.nmconnection"
  [ "$status" -eq 1 ]
  [ "$output" = "network-profiles: it has no type= in a [connection] group" ]
  [ -e "$tmp/office.nmconnection" ]
  run bash "$script" check
  [ "$status" -eq 2 ]
  run bash "$script" extra
  [ "$status" -eq 2 ]
}

# refused NAME REASON: check refuses NAME (already written to $tmp/c/NAME)
# with REASON.
refused() {
  run bash "$script" check "$tmp/c/$1"
  [ "$status" -eq 1 ] || { echo "accepted: $1"; return 1; }
  [ "$output" = "network-profiles: $2" ] || { echo "$1: $output"; return 1; }
}

@test "check refuses names, file kinds and sizes a profile cannot have" {
  mkdir -p "$tmp/c"
  for name in -x.nmconnection 'my wifi.nmconnection' 'wifi$.nmconnection' x.NMCONNECTION x.nmconnection.bak \
    "$(printf 'a%.0s' $(seq 65)).nmconnection"; do
    static x >"$tmp/c/$name"
    refused "$name" "the name is not <name>.nmconnection with 1 to 64 of A-Z a-z 0-9 . _ -"
  done
  static x >"$tmp/c/$(printf 'a%.0s' $(seq 64)).nmconnection"
  run bash "$script" check "$tmp/c/$(printf 'a%.0s' $(seq 64)).nmconnection"
  [ "$status" -eq 0 ]
  mkdir "$tmp/c/dir.nmconnection"
  refused dir.nmconnection "it is not a file"
  static x >"$tmp/c/target"
  ln -s target "$tmp/c/link.nmconnection"
  refused link.nmconnection "it is not a file"
  : >"$tmp/c/empty.nmconnection"
  refused empty.nmconnection "it is empty"
  { static x; head -c 65536 /dev/zero | tr '\0' '#'; } >"$tmp/c/big.nmconnection"
  refused big.nmconnection "it is larger than 64 KiB"
  printf '[connection]\ntype=ethernet\nid=a\0b\n' >"$tmp/c/nul.nmconnection"
  refused nul.nmconnection "it holds a NUL byte"
  printf '[connection]\ntype=ethernet\nid=caf\xe9\n' >"$tmp/c/latin1.nmconnection"
  refused latin1.nmconnection "it is not UTF-8 text"
}

@test "check refuses what NetworkManager could not read as a keyfile, or not as a profile" {
  mkdir -p "$tmp/c"
  printf 'type=ethernet\n[connection]\n' >"$tmp/c/a.nmconnection"
  refused a.nmconnection "line 1: a key=value line before the first [group]"
  printf '[connection]\ntype=ethernet\nnothing here\n' >"$tmp/c/b.nmconnection"
  refused b.nmconnection "line 3 is not a key=value line"
  printf '# x\n[connection\ntype=ethernet\n' >"$tmp/c/c.nmconnection"
  refused c.nmconnection "line 2 is not a [group] line"
  printf '[connection]\n=ethernet\n' >"$tmp/c/d.nmconnection"
  refused d.nmconnection "line 2 is not a key=value line"
  printf '[connection]\ntype[de]=ethernet\n' >"$tmp/c/e.nmconnection"
  refused e.nmconnection "line 2: not a key name"
  printf '[connection]\nid=x\n[ethernet]\ntype=ethernet\n' >"$tmp/c/f.nmconnection"
  refused f.nmconnection "it has no type= in a [connection] group"
  printf '[connection]\ntype=Ethernet!\n' >"$tmp/c/g.nmconnection"
  refused g.nmconnection "type= is not a NetworkManager connection type"
  printf '[connection]\ntype=ethernet\nuuid=not-a-uuid\n' >"$tmp/c/h.nmconnection"
  refused h.nmconnection "uuid= is not a UUID"
  # What it accepts: comments, blank lines, indentation, spaces around =,
  # whitespace after a group, a value with spaces, no uuid.
  printf '# made by hand\n\n  [connection]  \n  id = My Office\n type = ethernet\n\n[ipv4]\nmethod=auto\n' >"$tmp/c/ok.nmconnection"
  run bash "$script" check "$tmp/c/ok.nmconnection"
  [ "$status" -eq 0 ]
}

@test "a refused profile is renamed and its reason goes to stderr; the others are taken; the unit fails" {
  static good.nmconnection >"$src/good.nmconnection"
  printf '[connection]\nid=x\n' >"$src/bad.nmconnection"
  printf 'old refusal\n' >"$src/bad.nmconnection.refused"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused bad.nmconnection: it has no type= in a [connection] group; renamed to bad.nmconnection.refused"* ]]
  [ ! -e "$src/bad.nmconnection" ]
  grep -qx 'id=x' "$src/bad.nmconnection.refused"
  [ ! -e "$dest/bad.nmconnection" ]
  [ -e "$dest/good.nmconnection" ]
  [ ! -e "$src/good.nmconnection" ]
  # The next boot has nothing to take and nothing to refuse.
  run bash "$script"
  [ "$status" -eq 0 ]
  [ -e "$src/bad.nmconnection.refused" ]
  # The reason reaches stderr, which the unit sends to the console too.
  static bad2.nmconnection >"$src/bad2.nmconnection"
  printf '\0' >>"$src/bad2.nmconnection"
  bash "$script" 2>"$tmp/stderr" >/dev/null || true
  grep -q 'refused bad2.nmconnection: it holds a NUL byte' "$tmp/stderr"
}

@test "while a factory reset is pending or has begun the profiles wait; a refused request holds nothing back" {
  static office.nmconnection >"$src/office.nmconnection"
  for marker in factory-reset.conf factory-reset.keep; do
    : >"$tmp/esp/$marker"
    run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a factory reset is pending: the profiles on the FLOCKOS partition wait for it"* ]]
    [ -e "$src/office.nmconnection" ]
    [ ! -e "$dest/office.nmconnection" ]
    rm "$tmp/esp/$marker"
  done
  : >"$tmp/esp/factory-reset.conf.refused"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ -e "$dest/office.nmconnection" ]
  [ ! -e "$src/office.nmconnection" ]
}

@test "a power loss: a part file of /data is cleared, and a profile still on the partition is taken again" {
  static office.nmconnection >"$src/office.nmconnection"
  printf 'half' >"$dest/.flockos-profile-office.nmconnection.part"
  # Taken before, not yet removed from the partition.
  static office.nmconnection >"$dest/office.nmconnection"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$dest" | grep -v '^office.nmconnection$')" ]
  cmp "$dest/office.nmconnection" <(static office.nmconnection)
  [ ! -e "$src/office.nmconnection" ]
}

@test "a profile that cannot leave the FLOCKOS partition is taken all the same, again at the next boot; the unit fails" {
  if [ "$(id -u)" = 0 ]; then skip "root ignores the folder modes this test relies on"; fi
  static office.nmconnection >"$src/office.nmconnection"
  chmod 555 "$src"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not remove office.nmconnection from the FLOCKOS partition: the next boot takes it again"* ]]
  [ -e "$dest/office.nmconnection" ]
  [ -e "$src/office.nmconnection" ]
  chmod 755 "$src"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ ! -e "$src" ]
  cmp "$dest/office.nmconnection" <(static office.nmconnection)
}

@test "a folder or a link of the profile's name on /data takes nothing and loses nothing; the unit fails" {
  static office.nmconnection >"$src/office.nmconnection"
  mkdir "$dest/office.nmconnection"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"office.nmconnection: $dest/office.nmconnection is no profile file; office.nmconnection stays on the FLOCKOS partition"* ]]
  [[ "$output" != *"took office.nmconnection"* ]]
  [ -z "$(ls -A "$dest/office.nmconnection")" ]
  cmp "$src/office.nmconnection" <(static office.nmconnection)
  [ -z "$(ls -A "$dest" | grep -v '^office.nmconnection$')" ]
  # A link to a folder the same.
  rmdir "$dest/office.nmconnection"
  mkdir "$tmp/elsewhere"
  ln -s "$tmp/elsewhere" "$dest/office.nmconnection"
  run bash "$script"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$tmp/elsewhere")" ]
  [ -e "$src/office.nmconnection" ]
}

@test "a FLOCKOS partition that turned read-only: an old .refused that cannot go keeps back none of the profiles after it" {
  if [ "$(id -u)" = 0 ]; then skip "root ignores the folder modes this test relies on"; fi
  printf '[connection]\nid=x\n' >"$src/a-bad.nmconnection"
  printf 'old refusal\n' >"$src/a-bad.nmconnection.refused"
  static b-good.nmconnection >"$src/b-good.nmconnection"
  chmod 555 "$src"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused a-bad.nmconnection"* ]]
  [[ "$output" == *"could not rename a-bad.nmconnection: it is refused again at the next boot"* ]]
  [[ "$output" == *"took b-good.nmconnection (ethernet)"* ]]
  [ -e "$dest/b-good.nmconnection" ]
  [ "$(cat "$src/a-bad.nmconnection.refused")" = "old refusal" ]
}

@test "a run cut short (the time limit, a power loss) has removed every profile it finished from the partition; the next boot takes the rest" {
  for n in a b c; do static "$n.nmconnection" "$n$n$n$n$n$n$n$n-2222-4333-8444-555555555555" >"$src/$n.nmconnection"; done
  # Two syncs per profile (the file, then the folder of the rename): the
  # third stops the run while it writes b.
  echo 3 >"$tmp/sync.kill"
  run bash "$script"
  [ "$status" -ne 0 ]
  [ -e "$dest/a.nmconnection" ]
  [ ! -e "$src/a.nmconnection" ]
  [ -e "$src/b.nmconnection" ]
  [ -e "$src/c.nmconnection" ]
  [ ! -e "$dest/c.nmconnection" ]
  rm "$tmp/sync.kill"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$dest" | grep -vxE '[abc]\.nmconnection')" ]
  [ "$(ls "$dest" | wc -l | tr -d ' ')" = 3 ]
  [ ! -e "$src" ]
}

@test "the device's uuids are read once, not once per profile and file" {
  real=$(command -v awk)
  printf '#!/bin/sh\necho x >>"%s/awk.log"\nexec "%s" "$@"\n' "$tmp" "$real" >"$tmp/bin/awk"
  chmod +x "$tmp/bin/awk"
  for i in $(seq 20); do
    static "dev$i.nmconnection" "$(printf '%08d-0000-4000-8000-%012d' "$i" "$i")" >"$dest/dev$i.nmconnection"
    static "new$i.nmconnection" "$(printf '%08d-0000-4000-8000-%012d' $((i + 10)) $((i + 10)))" >"$src/new$i.nmconnection"
  done
  run bash "$script"
  [ "$status" -eq 0 ]
  # new1 to new10 have the uuids of dev11 to dev20, which they replace.
  [ "$(ls "$dest" | wc -l | tr -d ' ')" = 30 ]
  for i in $(seq 11 20); do [ ! -e "$dest/dev$i.nmconnection" ]; done
  [ -e "$dest/dev10.nmconnection" ]
  [ -e "$dest/new20.nmconnection" ]
  # One awk per profile for its check, one for the device's uuids; once per
  # pair it would be 420.
  [ "$(wc -l <"$tmp/awk.log" | tr -d ' ')" -le 22 ]
}

@test "a missing profile folder on /data is made, readable by root only" {
  rm -r "$tmp/data/network"
  static office.nmconnection >"$src/office.nmconnection"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ "$(mode "$dest")" = 700 ]
  [ -e "$dest/office.nmconnection" ]
}

@test "the keyfile grammar under mawk, as Debian's awk" {
  command -v mawk >/dev/null || skip "mawk is not installed"
  ln -s "$(command -v mawk)" "$tmp/bin/awk"
  static office.nmconnection >"$src/office.nmconnection"
  printf '[connection\ntype=ethernet\n' >"$src/bad.nmconnection"
  run bash "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused bad.nmconnection: line 1 is not a [group] line"* ]]
  [ -e "$dest/office.nmconnection" ]
}

@test "the unit runs before NetworkManager, after /data and its folders, whenever a profile lies there" {
  u=$units/flockos-network-profiles.service
  grep -qx 'ExecStart=/usr/lib/flockos/network-profiles' "$u"
  grep -qx 'RequiresMountsFor=/data /boot/efi' "$u"
  grep -qx 'After=local-fs.target flockos-data-layout.service' "$u"
  grep -qx 'Before=NetworkManager.service' "$u"
  grep -qx 'ConditionPathExistsGlob=/boot/efi/network/\*.nmconnection' "$u"
  grep -qx 'StandardError=journal+console' "$u"
  # NetworkManager waits for it, at most this long.
  grep -qx 'TimeoutStartSec=2min' "$u"
  grep -qx 'WantedBy=multi-user.target' "$u"
  # Where it puts them is what NetworkManager reads, readable by root only.
  grep -q '^/data/network/connections  */etc/NetworkManager/system-connections ' "$repo/overlay/etc/fstab"
  grep -qx 'path=/etc/NetworkManager/system-connections' "$repo/overlay/etc/NetworkManager/conf.d/10-flockos.conf"
  grep -qx 'chmod 0700 "$d/network/connections"' "$repo/overlay/usr/lib/flockos/data-layout"
  # A factory reset runs before /data is mounted, so before this unit.
  grep -q '^Before=.*data.mount' "$units/flockos-factory-reset.service"
  # Enroll, which writes the .flock's Wi-Fi profile, comes after NetworkManager.
  grep -q '^After=.*NetworkManager.service' "$units/flockos-enroll.service"
  # Enabled on devices; the installer has no /data.
  grep -qx '  systemctl --root="$ROOT" enable flockos-network-profiles.service' "$repo/build/customize.sh"
  grep -qx '  systemctl --root="$ROOT" mask flockos-network-profiles.service' "$repo/build/customize.sh"
  for check in "$repo/test/image/rpi-check.sh" "$repo/test/image/jetson-rootfs-check.sh"; do
    grep -q 'flockos-network-profiles.service; do' "$check"
  done
}
