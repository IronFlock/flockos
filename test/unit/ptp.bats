#!/usr/bin/env bats
# Time (docs/build.md, "Time"): chrony keeps it; ptp.conf adds PTP as chrony's
# source through ptp4l and phc2sys.

repo="$BATS_TEST_DIRNAME/../.."
ptp="$repo/overlay/usr/lib/flockos/ptp"
units="$repo/overlay/usr/lib/systemd/system"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin"
  # systemctl: records its arguments.
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$tmp" >"$tmp/bin/systemctl"
  chmod +x "$tmp/bin/systemctl"
  export PATH="$tmp/bin:$PATH" FLOCKOS_PTP_CONF=$tmp/ptp.conf FLOCKOS_RUN=$tmp/run
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

@test "an interface turns PTP on with the defaults: client only, domain 0, UDPv4, E2E, hardware stamps" {
  printf 'interface=enp88s0\n' >"$tmp/ptp.conf"
  run bash "$ptp"
  [ "$status" -eq 0 ]
  c=$tmp/run/ptp/ptp4l.conf
  grep -qx 'clientOnly 1' "$c"
  grep -qx 'domainNumber 0' "$c"
  grep -qx 'network_transport UDPv4' "$c"
  grep -qx 'delay_mechanism E2E' "$c"
  grep -qx 'time_stamping hardware' "$c"
  grep -qx '\[enp88s0\]' "$c"
  grep -qx 'PTP_DOMAIN=0' "$tmp/run/ptp/phc2sys.env"
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

@test "refuses what is not an interface name or a known key and value, and changes nothing" {
  for bad in 'interface=eth0 eth1' 'interface=$(reboot)' 'interface=eth0]' 'interface=abcdefghijklmnop' \
    'domain=256' 'domain=-1' 'domain=' 'transport=udp' 'delay=e2' 'role=master' 'interface'; do
    printf '%s\n' "$bad" >"$tmp/ptp.conf"
    run bash "$ptp"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [ ! -e "$tmp/run/ptp/ptp4l.conf" ]
  done
}

@test "apply restarts chrony, ptp4l and phc2sys on a change, and nothing when it is the same" {
  printf 'interface=enp88s0\n' >"$tmp/ptp.conf"
  run bash "$ptp" apply
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/systemctl.log")" = "restart chrony.service flockos-ptp4l.service flockos-phc2sys.service" ]
  rm "$tmp/systemctl.log"
  bash "$ptp" apply
  [ ! -e "$tmp/systemctl.log" ]
  printf 'interface=enp88s0\ndomain=1\n' >"$tmp/ptp.conf"
  bash "$ptp" apply
  [ "$(cat "$tmp/systemctl.log")" = "restart chrony.service flockos-ptp4l.service flockos-phc2sys.service" ]
}

@test "apply without an interface stops ptp4l and phc2sys and takes chrony's PTP source away" {
  printf 'interface=enp88s0\n' >"$tmp/ptp.conf"
  bash "$ptp"
  rm "$tmp/ptp.conf"
  run bash "$ptp" apply
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/run/chrony/ptp.conf" ] && [ ! -e "$tmp/run/ptp/ptp4l.conf" ] && [ ! -e "$tmp/run/ptp/phc2sys.env" ]
  [ "$(cat "$tmp/systemctl.log")" = "$(printf 'stop flockos-phc2sys.service flockos-ptp4l.service\ntry-restart chrony.service')" ]
}

@test "the units, chrony and the script name the same files and socket" {
  grep -qx 'ConditionPathExists=/run/flockos/ptp/ptp4l.conf' "$units/flockos-ptp4l.service"
  grep -q -- '-f /run/flockos/ptp/ptp4l.conf$' "$units/flockos-ptp4l.service"
  grep -qx 'ConditionPathExists=/run/flockos/ptp/phc2sys.env' "$units/flockos-phc2sys.service"
  grep -qx 'EnvironmentFile=/run/flockos/ptp/phc2sys.env' "$units/flockos-phc2sys.service"
  grep -q -- '-n ${PTP_DOMAIN} .*--refclock_sock_address /run/chrony/ptp.sock' "$units/flockos-phc2sys.service"
  grep -qx 'PartOf=chrony.service' "$units/flockos-phc2sys.service"
  grep -qx 'confdir /run/flockos/chrony' "$repo/overlay/etc/chrony/conf.d/10-flockos.conf"
  grep -qx 'PathChanged=/data/flockos/ptp.conf' "$units/flockos-ptp.path"
  grep -qx 'ExecStart=/usr/lib/flockos/ptp apply' "$units/flockos-ptp-reload.service"
  grep -q '^Before=chrony.service' "$units/flockos-ptp.service"
  grep -q 'ln -sfn /data/flockos/ptp.conf "$ROOT/etc/flockos/ptp.conf"' "$repo/build/customize.sh"
  grep -q 'chrony.service flockos-ptp.service flockos-ptp4l.service flockos-phc2sys.service' "$repo/build/customize.sh"
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
