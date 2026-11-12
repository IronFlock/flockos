#!/usr/bin/env bats
# Proxy (docs/build.md, "Proxy"): proxy.conf to the environment of the agent,
# Docker and containerd, with the .flock's LAN hosts off the proxy; ntp= to
# chrony; a proxy.conf on the IRONFLOCKOS partition replaces the device's.

repo="$BATS_TEST_DIRNAME/../.."
proxy="$repo/overlay/usr/lib/ironflockos/proxy"
units="$repo/overlay/usr/lib/systemd/system"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/esp" "$tmp/data" "$tmp/agent"
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$tmp" >"$tmp/bin/systemctl"
  printf '#!/bin/sh\necho "$*" >>"%s/chronyc.log"\n' "$tmp" >"$tmp/bin/chronyc"
  chmod +x "$tmp/bin/"*
  export PATH="$tmp/bin:$PATH" IRONFLOCKOS_PROXY_CONF=$tmp/data/proxy.conf IRONFLOCKOS_ESP=$tmp/esp \
    IRONFLOCKOS_RUN=$tmp/run IRONFLOCKOS_AGENT_FLOCK=$tmp/agent/device-config.flock
  env=$tmp/run/proxy.env
}

teardown() { rm -rf "$tmp"; }

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
value() { sed -n "s/^$1=//p" "$env"; }

@test "without proxy.conf: no proxy, no NTP servers, nothing restarted" {
  run bash "$proxy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proxy: none"* ]]
  [ ! -e "$env" ] && [ ! -e "$tmp/run/chrony-sources/ironflockos.sources" ]
  [ ! -e "$tmp/systemctl.log" ]
}

@test "http_proxy serves https too, in both spellings, localhost off the proxy, readable by root only" {
  printf 'http_proxy=http://proxy.corp.example:3128\n' >"$tmp/data/proxy.conf"
  run bash "$proxy"
  [ "$status" -eq 0 ]
  [ "$(value HTTP_PROXY)" = http://proxy.corp.example:3128 ]
  [ "$(value HTTPS_PROXY)" = http://proxy.corp.example:3128 ]
  [ "$(value https_proxy)" = http://proxy.corp.example:3128 ]
  [ "$(value NO_PROXY)" = localhost,127.0.0.1,::1 ]
  [ "$(value no_proxy)" = localhost,127.0.0.1,::1 ]
  [ "$(mode "$env")" = 600 ]
  [ ! -e "$tmp/systemctl.log" ]
}

@test "upper-case keys, quotes, comments and CRLF; the password stays out of the log" {
  printf '# corporate proxy\r\nHTTPS_PROXY = "http://user:p%%40ss@proxy:8080"   # with login\r\n' >"$tmp/data/proxy.conf"
  run bash "$proxy"
  [ "$status" -eq 0 ]
  [ "$(value HTTPS_PROXY)" = 'http://user:p%40ss@proxy:8080' ]
  [ -z "$(value HTTP_PROXY)" ]
  [[ "$output" == *"http://***@proxy:8080"* ]]
  [[ "$output" != *"p%40ss"* ]]
}

@test "NO_PROXY: the .flock's appliance domain and LAN registries, as the agent's installer adds them, then no_proxy" {
  printf 'http_proxy=http://proxy:3128\nno_proxy=10.0.0.0/8,.corp.example,localhost\n' >"$tmp/data/proxy.conf"
  cat >"$tmp/agent/device-config.flock" <<'JSON'
{"appliance_domain": "Appliance.Local",
 "insecure-registries": "[\"192.168.1.10:5000\", \"http://reg.lan:8080/v2\", \"[fd00::5]:5000\", \"fe80::1\"]",
 "docker_registry_url": "appliance.local:15001/"}
JSON
  run bash "$proxy"
  [ "$status" -eq 0 ]
  [ "$(value NO_PROXY)" = "localhost,127.0.0.1,::1,appliance.local,.appliance.local,192.168.1.10,reg.lan,fd00::5,fe80::1,10.0.0.0/8,.corp.example" ]
}

@test "on a first boot the .flock on the IRONFLOCKOS partition decides, not an old copy" {
  printf 'http_proxy=http://proxy:3128\n' >"$tmp/data/proxy.conf"
  echo '{"appliance_domain": "old.example"}' >"$tmp/agent/device-config.flock"
  echo '{"appliance_domain": "new.example", "insecure-registries": "lan-registry:5000"}' >"$tmp/esp/device.flock"
  bash "$proxy"
  [ "$(value NO_PROXY)" = "localhost,127.0.0.1,::1,new.example,.new.example,lan-registry" ]
}

@test "a proxy.conf on the IRONFLOCKOS partition replaces the device's and leaves the partition" {
  printf 'http_proxy=http://old:3128\n' >"$tmp/data/proxy.conf"
  printf 'http_proxy=http://new:3128\nntp=10.1.1.1\n' >"$tmp/esp/proxy.conf"
  run bash "$proxy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"took proxy.conf from the IRONFLOCKOS partition"* ]]
  [ ! -e "$tmp/esp/proxy.conf" ]
  grep -qx 'http_proxy=http://new:3128' "$tmp/data/proxy.conf"
  [ "$(mode "$tmp/data/proxy.conf")" = 600 ]
  [ "$(value HTTP_PROXY)" = http://new:3128 ]
}

@test "a IRONFLOCKOS proxy.conf with the execute bits FAT shows becomes the device's with mode 600" {
  printf 'http_proxy=http://new:3128\n' >"$tmp/esp/proxy.conf"
  chmod 0755 "$tmp/esp/proxy.conf"
  run bash "$proxy"
  [ "$status" -eq 0 ]
  [ "$(mode "$tmp/data/proxy.conf")" = 600 ]
  # Also over a device file that had another mode, and a stale part file.
  printf 'http_proxy=http://newer:3128\n' >"$tmp/esp/proxy.conf"
  chmod 0755 "$tmp/esp/proxy.conf"
  chmod 0644 "$tmp/data/proxy.conf"
  printf 'stale' >"$tmp/data/proxy.conf.new"
  chmod 0755 "$tmp/data/proxy.conf.new"
  run bash "$proxy"
  [ "$status" -eq 0 ]
  [ "$(mode "$tmp/data/proxy.conf")" = 600 ]
  grep -qx 'http_proxy=http://newer:3128' "$tmp/data/proxy.conf"
}

@test "a IRONFLOCKOS proxy.conf with an error stays there; the device keeps its own, and the unit fails" {
  printf 'http_proxy=http://old:3128\n' >"$tmp/data/proxy.conf"
  printf 'http_proxy=proxy-without-scheme:3128\n' >"$tmp/esp/proxy.conf"
  run bash "$proxy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignored the IRONFLOCKOS partition's proxy.conf"* ]]
  [ -e "$tmp/esp/proxy.conf" ]
  grep -qx 'http_proxy=http://old:3128' "$tmp/data/proxy.conf"
  [ "$(value HTTP_PROXY)" = http://old:3128 ]
}

@test "refuses what is not a proxy URL, a host list or a known key, and changes nothing" {
  printf 'http_proxy=http://good:3128\n' >"$tmp/data/proxy.conf"
  bash "$proxy"
  for bad in 'http_proxy=proxy:3128' 'http_proxy=ftp://proxy:21' 'http_proxy=http://a b' "http_proxy=http://x'y" \
    'http_proxy=http://$(reboot)' 'http_proxy=http://x`id`' 'http_proxy="http://x' 'no_proxy=a;b' 'no_proxy=a b' \
    'ntp=a b' 'ntp=$(id)' 'colour=blue' 'http_proxy'; do
    printf '%s\n' "$bad" >"$tmp/data/proxy.conf"
    run bash "$proxy" apply
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [ "$(value HTTP_PROXY)" = http://good:3128 ]
  done
  [ ! -e "$tmp/systemctl.log" ]
}

@test "ntp= becomes chrony sources, readable by chronyd, and apply has chronyd reload them" {
  printf 'ntp=10.0.0.1,ntp.corp.example\n' >"$tmp/data/proxy.conf"
  run bash "$proxy" apply
  [ "$status" -eq 0 ]
  s=$tmp/run/chrony-sources/ironflockos.sources
  grep -qx 'server 10.0.0.1 iburst' "$s"
  grep -qx 'server ntp.corp.example iburst' "$s"
  [ "$(mode "$s")" = 644 ]
  [ "$(cat "$tmp/chronyc.log")" = "reload sources" ]
  # NTP servers alone need no proxy, and restart nothing.
  [ ! -e "$env" ] && [ ! -e "$tmp/systemctl.log" ]
  : >"$tmp/data/proxy.conf"
  bash "$proxy" apply
  [ ! -e "$s" ]
}

@test "apply restarts containerd, Docker and the agent on a change only, and never takes the IRONFLOCKOS file" {
  printf 'http_proxy=http://proxy:3128\n' >"$tmp/data/proxy.conf"
  run bash "$proxy" apply
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/systemctl.log")" = "try-restart containerd.service docker.service ironflock-device-agent.service" ]
  rm "$tmp/systemctl.log"
  printf 'http_proxy=http://other:3128\n' >"$tmp/esp/proxy.conf"
  bash "$proxy" apply
  [ ! -e "$tmp/systemctl.log" ]
  [ -e "$tmp/esp/proxy.conf" ]
  rm "$tmp/data/proxy.conf"
  bash "$proxy" apply
  [ ! -e "$env" ]
  [ "$(cat "$tmp/systemctl.log")" = "try-restart containerd.service docker.service ironflock-device-agent.service" ]
}

@test "the units, the drop-ins, chrony, the build and the installer name the same files" {
  for u in docker containerd ironflock-device-agent; do
    grep -qx 'EnvironmentFile=-/run/ironflockos/proxy.env' "$units/$u.service.d/20-ironflockos-proxy.conf"
  done
  grep -q '^Before=containerd.service docker.service ironflock-device-agent.service chrony.service$' "$units/ironflockos-proxy.service"
  # Not after enroll, which runs after Docker: that would be a cycle.
  [ -z "$(grep -E '^After=.*ironflockos-enroll' "$units/ironflockos-proxy.service")" ]
  grep -q '^After=docker.service' "$units/ironflockos-enroll.service"
  grep -qx 'PathChanged=/data/ironflockos/proxy.conf' "$units/ironflockos-proxy.path"
  grep -qx 'ExecStart=/usr/lib/ironflockos/proxy apply' "$units/ironflockos-proxy-reload.service"
  grep -qx 'sourcedir /run/ironflockos/chrony-sources' "$repo/overlay/etc/chrony/conf.d/10-ironflockos.conf"
  grep -q 'ln -sfn /data/ironflockos/proxy.conf "$ROOT/etc/ironflockos/proxy.conf"' "$repo/build/customize.sh"
  grep -qE 'ironflockos-proxy.service( |$)' "$repo/build/customize.sh"
  grep -qE 'systemd-repart.service ironflockos-proxy.service ironflockos-proxy.path ironflockos-proxy-reload.service( |$)' "$repo/build/customize.sh"
  grep -q 'carry+=("$esp/proxy.conf")' "$repo/profiles/installer/overlay/usr/lib/ironflockos/installer"
}
