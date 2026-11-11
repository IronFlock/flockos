#!/usr/bin/env bats
# Time (docs/build.md, "Time"): chrony keeps it; ptp.conf adds PTP through
# ptp4l and phc2sys, as chrony's source (client) or served from the system
# clock (server).

repo="$BATS_TEST_DIRNAME/../.."
ptp="$repo/overlay/usr/lib/ironflockos/ptp"
units="$repo/overlay/usr/lib/systemd/system"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin"
  # systemctl, phc2sys, chronyc: record their arguments; chronyc exits with
  # $CHRONYC_RC.
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$tmp" >"$tmp/bin/systemctl"
  printf '#!/bin/sh\necho "$*" >>"%s/phc2sys.log"\n' "$tmp" >"$tmp/bin/phc2sys"
  printf '#!/bin/sh\necho "$*" >>"%s/chronyc.log"\nexit ${CHRONYC_RC:-0}\n' "$tmp" >"$tmp/bin/chronyc"
  chmod +x "$tmp/bin/"*
  export PATH="$tmp/bin:$PATH" IRONFLOCKOS_PTP_CONF=$tmp/ptp.conf IRONFLOCKOS_RUN=$tmp/run
}

teardown() { rm -rf "$tmp"; }

@test "without ptp.conf: PTP off, nothing for ptp4l, phc2sys or chrony" {
  run bash "$ptp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ptp: off"* ]]
  [ -d "$tmp/run/chrony" ]
  [ -z "$(find "$tmp/run" -type f)" ]
  [ ! -e "$tmp/systemctl.log" ]
}

@test "an interface makes a client with the defaults: domain 0, UDPv4, E2E, hardware stamps, chrony's source" {
  printf 'interface=enp88s0\npriority1=10\n' >"$tmp/ptp.conf"
  run bash "$ptp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ptp: client on enp88s0"* ]]
  c=$tmp/run/ptp/ptp4l.conf
  grep -qx 'clientOnly 1' "$c"
  grep -qx 'domainNumber 0' "$c"
  grep -qx 'network_transport UDPv4' "$c"
  grep -qx 'delay_mechanism E2E' "$c"
  grep -qx 'time_stamping hardware' "$c"
  grep -qx '\[enp88s0\]' "$c"
  # priority1 is a server's; a client announces nothing.
  [ -z "$(grep -E 'serverOnly|priority1' "$c")" ]
  [ "$(cat "$tmp/run/ptp/phc2sys.env")" = "$(printf 'PTP_ROLE=client\nPTP_DOMAIN=0\nPTP_INTERFACE=enp88s0')" ]
  grep -qx 'refclock SOCK /run/chrony/ptp.sock refid PTP poll 2 filter 4 precision 1e-9 delay 1e-4' "$tmp/run/chrony/ptp.conf"
  # At boot the units start on the files; nothing is restarted.
  [ ! -e "$tmp/systemctl.log" ]
}

@test "domain, transport and delay mechanism reach ptp4l and phc2sys" {
  printf '# machine network\ninterface=eth0\r\ndomain=024\ntransport=l2\ndelay=p2p\n' >"$tmp/ptp.conf"
  run bash "$ptp"
  [ "$status" -eq 0 ]
  grep -qx 'domainNumber 24' "$tmp/run/ptp/ptp4l.conf"
  grep -qx 'network_transport L2' "$tmp/run/ptp/ptp4l.conf"
  grep -qx 'delay_mechanism P2P' "$tmp/run/ptp/ptp4l.conf"
  grep -qx 'PTP_DOMAIN=24' "$tmp/run/ptp/phc2sys.env"
  printf 'interface=eth0\ntransport=udp6\n' >"$tmp/ptp.conf"
  bash "$ptp"
  grep -qx 'network_transport UDPv6' "$tmp/run/ptp/ptp4l.conf"
}

@test "role=server: master only with priority1 64 or the one given, and no source for chrony" {
  printf 'interface=enp89s0\nrole=server\n' >"$tmp/ptp.conf"
  run bash "$ptp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ptp: server on enp89s0, domain 0, udp4, e2e, priority1 64"* ]]
  c=$tmp/run/ptp/ptp4l.conf
  grep -qx 'serverOnly 1' "$c"
  grep -qx 'priority1 64' "$c"
  [ -z "$(grep clientOnly "$c")" ]
  grep -qx '\[enp89s0\]' "$c"
  grep -qx 'PTP_ROLE=server' "$tmp/run/ptp/phc2sys.env"
  [ ! -e "$tmp/run/chrony/ptp.conf" ]
  printf 'interface=enp89s0\nrole=server\npriority1=10\n' >"$tmp/ptp.conf"
  bash "$ptp"
  grep -qx 'priority1 10' "$c"
}

@test "the example in docs/build.md is a valid ptp.conf, comments after values included" {
  sed -n '/^## Time/,/^## /p' "$repo/docs/build.md" | sed -n '/^```ini$/,/^```$/p' | sed '1d;$d' >"$tmp/ptp.conf"
  grep -q '^interface=' "$tmp/ptp.conf"
  run bash "$ptp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ptp: client on enp88s0, domain 0, udp4, e2e"* ]]
  printf '  role=server   # indented, with a comment\n' >>"$tmp/ptp.conf"
  run bash "$ptp"
  [ "$status" -eq 0 ]
  grep -qx 'serverOnly 1' "$tmp/run/ptp/ptp4l.conf"
}

@test "refuses what is not an interface name or a known key and value, and changes nothing" {
  for bad in 'interface=eth0 eth1' 'interface=$(reboot)' 'interface=eth0]' 'interface=abcdefghijklmnop' \
    'domain=256' 'domain=-1' 'domain=' 'transport=udp' 'delay=e2' 'role=master' 'role=' \
    'priority1=256' 'priority1=high' 'colour=blue' 'interface'; do
    printf 'interface=eth0\n%s\n' "$bad" >"$tmp/ptp.conf"
    run bash "$ptp"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [ ! -e "$tmp/run/ptp/ptp4l.conf" ]
  done
}

@test "apply as a client restarts chrony, ptp4l and phc2sys on a change, and nothing when it is the same" {
  printf 'interface=enp88s0\n' >"$tmp/ptp.conf"
  run bash "$ptp" apply
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/systemctl.log")" = "restart chrony.service ironflockos-ptp4l.service ironflockos-phc2sys.service" ]
  rm "$tmp/systemctl.log"
  bash "$ptp" apply
  [ ! -e "$tmp/systemctl.log" ]
  printf 'interface=enp88s0\ndomain=1\n' >"$tmp/ptp.conf"
  bash "$ptp" apply
  [ "$(cat "$tmp/systemctl.log")" = "restart chrony.service ironflockos-ptp4l.service ironflockos-phc2sys.service" ]
}

@test "apply as a server leaves chrony alone, unless it drops a client's PTP source" {
  printf 'interface=enp88s0\n' >"$tmp/ptp.conf"
  bash "$ptp"
  printf 'interface=enp88s0\nrole=server\n' >"$tmp/ptp.conf"
  bash "$ptp" apply
  [ "$(cat "$tmp/systemctl.log")" = "restart chrony.service ironflockos-ptp4l.service ironflockos-phc2sys.service" ]
  [ ! -e "$tmp/run/chrony/ptp.conf" ]
  rm "$tmp/systemctl.log"
  printf 'interface=enp88s0\nrole=server\npriority1=20\n' >"$tmp/ptp.conf"
  bash "$ptp" apply
  [ "$(cat "$tmp/systemctl.log")" = "restart ironflockos-ptp4l.service ironflockos-phc2sys.service" ]
  rm "$tmp/systemctl.log"
  rm "$tmp/ptp.conf"
  bash "$ptp" apply
  [ "$(cat "$tmp/systemctl.log")" = "stop ironflockos-phc2sys.service ironflockos-ptp4l.service" ]
}

@test "apply without an interface stops ptp4l and phc2sys and takes chrony's PTP source away" {
  printf 'interface=enp88s0\n' >"$tmp/ptp.conf"
  bash "$ptp"
  rm "$tmp/ptp.conf"
  run bash "$ptp" apply
  [ "$status" -eq 0 ]
  [ -z "$(find "$tmp/run" -type f)" ]
  [ "$(cat "$tmp/systemctl.log")" = "$(printf 'stop ironflockos-phc2sys.service ironflockos-ptp4l.service\ntry-restart chrony.service')" ]
}

@test "phc2sys as a client: samples to chrony's socket while ptp4l follows a master" {
  printf 'interface=enp88s0\ndomain=3\n' >"$tmp/ptp.conf"
  bash "$ptp"
  run bash "$ptp" phc2sys
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/phc2sys.log")" = "-a -r -R 1 -E refclock_sock --refclock_sock_address /run/chrony/ptp.sock -n 3 -l 5 -m -q" ]
  [ ! -e "$tmp/chronyc.log" ]
}

@test "phc2sys as a server: the system clock to the interface, after chrony's sync or without it" {
  printf 'interface=enp89s0\nrole=server\ndomain=3\n' >"$tmp/ptp.conf"
  bash "$ptp"
  run bash "$ptp" phc2sys
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/chronyc.log")" = "waitsync 12 0.01" ]
  [ "$(cat "$tmp/phc2sys.log")" = "-s CLOCK_REALTIME -c enp89s0 -w -n 3 -l 5 -m -q" ]
  rm "$tmp/phc2sys.log"
  CHRONYC_RC=1 run bash "$ptp" phc2sys
  [ "$status" -eq 0 ]
  [[ "$output" == *"serving the clock as it is"* ]]
  [ -e "$tmp/phc2sys.log" ]
}

@test "the units, chrony and the script name the same files and socket" {
  grep -qx 'ConditionPathExists=/run/ironflockos/ptp/ptp4l.conf' "$units/ironflockos-ptp4l.service"
  grep -q -- '-f /run/ironflockos/ptp/ptp4l.conf$' "$units/ironflockos-ptp4l.service"
  grep -qx 'ConditionPathExists=/run/ironflockos/ptp/phc2sys.env' "$units/ironflockos-phc2sys.service"
  grep -qx 'ExecStart=/usr/lib/ironflockos/ptp phc2sys' "$units/ironflockos-phc2sys.service"
  grep -qx 'PartOf=chrony.service' "$units/ironflockos-phc2sys.service"
  grep -q -- '--refclock_sock_address /run/chrony/ptp.sock' "$ptp"
  grep -q 'refclock SOCK /run/chrony/ptp.sock ' "$ptp"
  grep -qx 'confdir /run/ironflockos/chrony' "$repo/overlay/etc/chrony/conf.d/10-ironflockos.conf"
  grep -qx 'PathChanged=/data/ironflockos/ptp.conf' "$units/ironflockos-ptp.path"
  grep -qx 'ExecStart=/usr/lib/ironflockos/ptp apply' "$units/ironflockos-ptp-reload.service"
  grep -q '^Before=chrony.service' "$units/ironflockos-ptp.service"
  grep -q 'ln -sfn /data/ironflockos/ptp.conf "$ROOT/etc/ironflockos/ptp.conf"' "$repo/build/customize.sh"
  grep -q 'chrony.service ironflockos-ptp.service ironflockos-ptp4l.service ironflockos-phc2sys.service' "$repo/build/customize.sh"
  # The first boot's presets keep that set, and nothing that takes chrony's place.
  p=$repo/overlay/usr/lib/systemd/system-preset/10-ironflockos-time.preset
  for u in chrony.service ironflockos-ptp.service ironflockos-ptp.path ironflockos-ptp4l.service ironflockos-phc2sys.service; do
    grep -qx "enable $u" "$p"
  done
  for u in chronyd-restricted.service timemaster.service chrony-wait.service; do
    grep -qx "disable $u" "$p"
  done
}

@test "chrony replaces systemd-timesyncd in every image, with linuxptp for PTP" {
  source "$repo/build/lib.sh"
  mapfile -t base < <(read_list "$repo/profiles/base/packages")
  printf '%s\n' "${base[@]}" | grep -qx chrony
  printf '%s\n' "${base[@]}" | grep -qx linuxptp
  # (a negated command does not fail a bats test, so these compare output)
  [ -z "$(printf '%s\n' "${base[@]}" | grep -x systemd-timesyncd)" ]
  [ -z "$(grep systemd-timesyncd "$repo/build/customize.sh")" ]
  grep -qx 'DAEMON_OPTS="-F 1 -s"' "$repo/overlay/etc/default/chrony"
}
