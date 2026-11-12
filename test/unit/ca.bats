#!/usr/bin/env bats
# Trusted CAs (docs/build.md, "Trusted CAs"; ADR-0021): a ca.crt on the
# IRONFLOCKOS partition replaces the device's set, refused as a whole when a
# block is no certificate; the set goes into the system's trust store, one
# file per certificate, and update-ca-certificates runs on a change only.

repo="$BATS_TEST_DIRNAME/../.."
ca="$repo/overlay/usr/lib/ironflockos/ca"
units="$repo/overlay/usr/lib/systemd/system"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/esp" "$tmp/data" "$tmp/certs"
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$tmp" >"$tmp/bin/systemctl"
  # update-ca-certificates: logs its call; fails while update-ca-fails exists.
  printf '#!/bin/sh\necho "$*" >>"%s/update-ca.log"\n[ ! -e "%s/update-ca-fails" ]\n' "$tmp" "$tmp" >"$tmp/update-ca"
  chmod +x "$tmp/bin/"* "$tmp/update-ca"
  export PATH="$tmp/bin:$PATH" IRONFLOCKOS_CA_CONF=$tmp/data/ca.crt IRONFLOCKOS_ESP=$tmp/esp \
    IRONFLOCKOS_RUN=$tmp/run IRONFLOCKOS_CA_DIR=$tmp/store IRONFLOCKOS_UPDATE_CA=$tmp/update-ca
  # A corporate root CA and its sub CA, and another root.
  cert root '/O=Example Corp/CN=Example Corp Root CA'
  cert sub '/O=Example Corp/CN=Example Corp Sub CA'
  cert other '/CN=Other Root CA'
}

teardown() { rm -rf "$tmp"; }

# cert NAME SUBJECT: a self-signed certificate in $tmp/certs/NAME.pem.
cert() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj "$2" \
    -keyout "$tmp/certs/$1.key" -out "$tmp/certs/$1.pem" 2>/dev/null
}

pem() { cat "$tmp/certs/$1.pem"; }
fp() { openssl x509 -in "$tmp/certs/$1.pem" -noout -fingerprint -sha256 | sed 's/^.*=//'; }
# The file in the store of certificate NAME.
stored() { echo "$tmp/store/ironflockos-$(fp "$1" | tr -d ':' | tr '[:upper:]' '[:lower:]').crt"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
store_files() { (cd "$tmp/store" 2>/dev/null && ls -A) | tr '\n' ' '; }
calls() { cat "$tmp/update-ca.log" 2>/dev/null | wc -l | tr -d ' '; }

@test "without ca.crt anywhere: no extra CA, the store untouched, nothing updated or restarted" {
  run bash "$ca"
  [ "$status" -eq 0 ]
  [ "$output" = "ca: no extra CA" ]
  [ ! -e "$tmp/store" ] && [ ! -e "$tmp/update-ca.log" ] && [ ! -e "$tmp/systemctl.log" ]
  run bash "$ca" apply
  [ "$status" -eq 0 ] && [ ! -e "$tmp/update-ca.log" ] && [ ! -e "$tmp/systemctl.log" ]
}

@test "a ca.crt on the IRONFLOCKOS partition becomes the device's set, leaves the partition, and reaches the store" {
  { echo '# the corporate chain'; pem root; echo; pem sub; echo '# end'; } >"$tmp/esp/ca.crt"
  chmod 0755 "$tmp/esp/ca.crt"
  run bash "$ca"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ca: took ca.crt from the IRONFLOCKOS partition"* ]]
  [[ "$output" == *"ca: trusts CN=Example Corp Root CA,O=Example Corp (SHA-256 $(fp root))"* ]]
  [[ "$output" == *"ca: trusts CN=Example Corp Sub CA,O=Example Corp (SHA-256 $(fp sub))"* ]]
  [ ! -e "$tmp/esp/ca.crt" ]
  # The device keeps the certificates alone, readable by all, as FAT's
  # execute bits never are.
  [ "$(cat "$tmp/data/ca.crt")" = "$(pem root; pem sub)" ]
  [ "$(mode "$tmp/data/ca.crt")" = 644 ]
  # One file per certificate, then update-ca-certificates, once.
  cmp -s "$(stored root)" "$tmp/certs/root.pem" && cmp -s "$(stored sub)" "$tmp/certs/sub.pem"
  [ "$(mode "$(stored root)")" = 644 ]
  [ "$(store_files)" = "$(basename "$(stored root)") $(basename "$(stored sub)") " ] ||
    [ "$(store_files)" = "$(basename "$(stored sub)") $(basename "$(stored root)") " ]
  [ "$(cat "$tmp/update-ca.log")" = "--fresh" ]
  # At boot nothing runs yet that would need a restart.
  [ ! -e "$tmp/systemctl.log" ]
}

@test "the next boot finds the store as it is: update-ca-certificates does not run again" {
  pem root >"$tmp/esp/ca.crt"
  bash "$ca"
  [ "$(calls)" = 1 ]
  run bash "$ca"
  [ "$status" -eq 0 ] && [[ "$output" == *"ca: trusts CN=Example Corp Root CA"* ]]
  [ "$(calls)" = 1 ]
  # The same set from the partition again changes nothing either.
  pem root >"$tmp/esp/ca.crt"
  bash "$ca"
  [ "$(calls)" = 1 ] && [ ! -e "$tmp/esp/ca.crt" ]
}

@test "a new slot (an update) has an empty store: its first boot puts the device's set in" {
  pem root >"$tmp/esp/ca.crt"
  bash "$ca"
  rm -rf "$tmp/store"
  run bash "$ca"
  [ "$status" -eq 0 ]
  cmp -s "$(stored root)" "$tmp/certs/root.pem"
  [ "$(calls)" = 2 ]
}

@test "a block that is no certificate: the partition's file is refused as a whole and stays; the device keeps its set; the unit fails" {
  pem root >"$tmp/esp/ca.crt"
  bash "$ca"
  for bad in 'block' 'no-end' 'begin-twice' 'binary'; do
    case "$bad" in
      block) { pem other; printf -- '-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydGlmaWNhdGU=\n-----END CERTIFICATE-----\n'; } >"$tmp/esp/ca.crt" ;;
      no-end) { pem other; pem sub | sed '$d'; } >"$tmp/esp/ca.crt" ;;
      begin-twice) { pem other | sed '$d'; pem sub; } >"$tmp/esp/ca.crt" ;;
      binary) openssl x509 -in "$tmp/certs/other.pem" -outform DER >"$tmp/esp/ca.crt" ;;
    esac
    run bash "$ca"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [[ "$output" == *"ignored the IRONFLOCKOS partition's ca.crt, which has an error; the device keeps its own"* ]]
    [[ "$output" == *"ca: trusts CN=Example Corp Root CA"* ]]
    [ -e "$tmp/esp/ca.crt" ]
    [ "$(cat "$tmp/data/ca.crt")" = "$(pem root)" ]
    [ ! -e "$(stored other)" ] && [ -e "$(stored root)" ]
  done
  [[ "$output" == *"is not text: ca.crt takes PEM certificates"* ]]
  [ "$(calls)" = 1 ]
}

@test "a ca.crt without a certificate block clears the device's set, and the store with it" {
  { pem root; pem sub; } >"$tmp/esp/ca.crt"
  bash "$ca"
  printf '# no extra CA from now on\r\n' >"$tmp/esp/ca.crt"
  run bash "$ca"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ca: took ca.crt from the IRONFLOCKOS partition"* ]]
  [[ "$output" == *"ca: no extra CA"* ]]
  [ ! -e "$tmp/data/ca.crt" ] && [ ! -e "$tmp/esp/ca.crt" ]
  [ ! -e "$tmp/store" ]
  [ "$(calls)" = 2 ]
  # So does an empty file, on a device without a set: nothing to update.
  : >"$tmp/esp/ca.crt"
  run bash "$ca"
  [ "$status" -eq 0 ] && [ ! -e "$tmp/esp/ca.crt" ] && [ "$(calls)" = 2 ]
}

@test "the forms of PEM: CRLF, a byte order mark, indented markers, the same certificate twice" {
  { printf '\xef\xbb\xbf'; pem root; echo '  '; pem sub | sed 's/^-----/  -----/'; pem root; } | sed 's/$/\r/' >"$tmp/esp/ca.crt"
  run bash "$ca"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/data/ca.crt")" = "$(pem root; pem sub)" ]
  [ "$(grep -c 'ca: trusts' <<<"$output")" = 2 ]
  [ "$(store_files | wc -w | tr -d ' ')" = 2 ]
}

@test "a factory reset that waits leaves the partition's ca.crt; copy takes it and leaves it there; gave-up waits; data-missing copies" {
  pem root >"$tmp/data/ca.crt"
  pem sub >"$tmp/esp/ca.crt"
  mkdir -p "$tmp/run"
  for hold in wait gave-up; do
    echo "$hold" >"$tmp/run/factory-reset-hold"
    run bash "$ca"
    [ "$status" -eq 0 ] && [[ "$output" == *"the IRONFLOCKOS partition's ca.crt waits for it"* ]]
    [ "$(cat "$tmp/data/ca.crt")" = "$(pem root)" ] && [ -e "$tmp/esp/ca.crt" ]
    [ -e "$(stored root)" ] && [ ! -e "$(stored sub)" ]
  done
  # wait wins over a missing /data.
  : >"$tmp/run/data-missing"
  echo wait >"$tmp/run/factory-reset-hold"
  bash "$ca"
  [ "$(cat "$tmp/data/ca.crt")" = "$(pem root)" ]
  echo copy >"$tmp/run/factory-reset-hold"
  rm "$tmp/run/data-missing"
  run bash "$ca"
  [ "$status" -eq 0 ] && [[ "$output" == *"took ca.crt from the IRONFLOCKOS partition and left it there"* ]]
  [ "$(cat "$tmp/data/ca.crt")" = "$(pem sub)" ] && [ -e "$tmp/esp/ca.crt" ]
  [ -e "$(stored sub)" ] && [ ! -e "$(stored root)" ]
  # Without /data, as with copy.
  rm "$tmp/run/factory-reset-hold" "$tmp/data/ca.crt"
  : >"$tmp/run/data-missing"
  run bash "$ca"
  [ "$status" -eq 0 ] && [[ "$output" == *"left it there"* ]] && [ -e "$tmp/esp/ca.crt" ]
  [ "$(cat "$tmp/data/ca.crt")" = "$(pem sub)" ]
  # No hold, /data there: taken as usual.
  rm "$tmp/run/data-missing"
  bash "$ca"
  [ ! -e "$tmp/esp/ca.crt" ]
}

@test "apply: syncs the store from the device's set, restarts containerd, Docker and the agent on a change only, never takes the partition's file" {
  pem root >"$tmp/data/ca.crt"
  run bash "$ca" apply
  [ "$status" -eq 0 ]
  [ -e "$(stored root)" ] && [ "$(calls)" = 1 ]
  [ "$(cat "$tmp/systemctl.log")" = "try-restart containerd.service docker.service ironflock-device-agent.service" ]
  rm "$tmp/systemctl.log"
  pem other >"$tmp/esp/ca.crt"
  bash "$ca" apply
  [ ! -e "$tmp/systemctl.log" ] && [ "$(calls)" = 1 ] && [ -e "$tmp/esp/ca.crt" ]
  # Another set: the certificate that went leaves the store.
  { pem sub; pem root; } >"$tmp/data/ca.crt"
  bash "$ca" apply
  [ -e "$(stored sub)" ] && [ -e "$(stored root)" ] && [ "$(calls)" = 2 ]
  pem sub >"$tmp/data/ca.crt"
  bash "$ca" apply
  [ -e "$(stored sub)" ] && [ ! -e "$(stored root)" ] && [ "$(calls)" = 3 ]
  # The set removed: the store's files go, and the directory.
  rm "$tmp/data/ca.crt" "$tmp/systemctl.log"
  run bash "$ca" apply
  [ "$status" -eq 0 ] && [ "$output" = "ca: no extra CA" ]
  [ ! -e "$tmp/store" ] && [ "$(calls)" = 4 ]
  [ "$(cat "$tmp/systemctl.log")" = "try-restart containerd.service docker.service ironflock-device-agent.service" ]
}

@test "a device set with an error changes nothing in the store" {
  pem root >"$tmp/data/ca.crt"
  bash "$ca" apply
  rm "$tmp/systemctl.log"
  printf -- '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n' >"$tmp/data/ca.crt"
  run bash "$ca" apply
  [ "$status" -ne 0 ] && [[ "$output" == *"ca: $tmp/data/ca.crt:1: the block is not a certificate openssl can read"* ]]
  [ -e "$(stored root)" ] && [ "$(calls)" = 1 ] && [ ! -e "$tmp/systemctl.log" ]
}

@test "update-ca-certificates fails: the unit fails, and the next run does it again" {
  pem root >"$tmp/esp/ca.crt"
  : >"$tmp/update-ca-fails"
  run bash "$ca"
  [ "$status" -ne 0 ] && [[ "$output" == *"update-ca-certificates failed"* ]]
  [ "$(calls)" = 1 ] && [ -e "$(stored root)" ]
  run bash "$ca"
  [ "$status" -ne 0 ] && [ "$(calls)" = 2 ]
  rm "$tmp/update-ca-fails"
  run bash "$ca"
  [ "$status" -eq 0 ] && [ "$(calls)" = 3 ]
  run bash "$ca"
  [ "$status" -eq 0 ] && [ "$(calls)" = 3 ]
  # So does a removal that failed.
  rm "$tmp/data/ca.crt"
  : >"$tmp/update-ca-fails"
  run bash "$ca" apply
  [ "$status" -ne 0 ] && [ ! -e "$(stored root)" ] && [ "$(calls)" = 4 ]
  rm "$tmp/update-ca-fails"
  run bash "$ca" apply
  [ "$status" -eq 0 ] && [ "$(calls)" = 5 ] && [ ! -e "$tmp/store" ]
}

@test "the units, the build and the installer name the same files" {
  grep -q '^Before=containerd.service docker.service ironflock-device-agent.service' "$units/ironflockos-ca.service"
  grep -qx 'ExecStart=/usr/lib/ironflockos/ca' "$units/ironflockos-ca.service"
  grep -qx 'Also=ironflockos-ca.path' "$units/ironflockos-ca.service"
  # Not after enroll, which runs after Docker: that would be a cycle.
  [ -z "$(grep -E '^After=.*ironflockos-enroll' "$units/ironflockos-ca.service")" ]
  grep -qx 'PathChanged=/data/ironflockos/ca.crt' "$units/ironflockos-ca.path"
  grep -qx 'Unit=ironflockos-ca-reload.service' "$units/ironflockos-ca.path"
  grep -qx 'ExecStart=/usr/lib/ironflockos/ca apply' "$units/ironflockos-ca-reload.service"
  grep -qx 'After=ironflockos-ca.service' "$units/ironflockos-ca-reload.service"
  grep -q 'ln -sfn /data/ironflockos/ca.crt "$ROOT/etc/ironflockos/ca.crt"' "$repo/build/customize.sh"
  grep -q 'ironflockos-ca.service ironflockos-ca.path ironflockos-ca-reload.service' "$repo/build/customize.sh"
  grep -q 'carry+=("$esp/ca.crt")' "$repo/profiles/installer/overlay/usr/lib/ironflockos/installer"
  # update-ca-certificates and openssl come with ca-certificates.
  grep -qx ca-certificates "$repo/profiles/base/packages"
  grep -qx openssl "$repo/profiles/base/packages"
}
