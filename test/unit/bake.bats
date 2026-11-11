#!/usr/bin/env bats
# build/bake.sh (WP-5.1 of the CLI's plan): ironflock from cli/ below the
# download base, checked against the pinned bootstrap key, and `ironflock
# bake` on the root tree. curl, sqv and ironflock are fakes; the download base
# is a folder.

repo="$BATS_TEST_DIRNAME/../.."
bake="$repo/build/bake.sh"
key="$repo/profiles/base/keys/ironflock-bootstrap.asc"
fingerprint=F6C94D96CE315377ACA7C8EA4990543373212788

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/www" "$tmp/root" "$tmp/work" "$tmp/out"
  # curl -fsSL ... -o FILE URL: the URL's file from $tmp/www, every URL in
  # curl-calls; a file that is not there fails as curl -f does.
  cat >"$tmp/bin/curl" <<EOF
#!/bin/bash
out="" url=""
while [ \$# -gt 0 ]; do
  case \$1 in
    -o) out=\$2; shift ;;
    --proto | --retry) shift ;;
    -*) ;;
    *) url=\$1 ;;
  esac
  shift
done
echo "\$url" >>"$tmp/curl-calls"
src="$tmp/www/\${url#https://dl.test/}"
[ -f "\$src" ] || exit 22
cp "\$src" "\$out"
EOF
  # sqv --keyring KEY SIG FILE: a signature that says "good" is good, by the
  # bootstrap key; the arguments go to sqv-calls.
  cat >"$tmp/bin/sqv" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/sqv-calls"
[ "\$(cat "\$3")" = good ] || { echo "sqv: bad signature" >&2; exit 1; }
echo $fingerprint
EOF
  chmod +x "$tmp/bin/curl" "$tmp/bin/sqv"
  publish arm64 2.0.1 '{"agent_version": "1.6.10", "ironflock_version": "2.0.1", "files": []}'
  export ROOT=$tmp/root WORK=$tmp/work OUT=$tmp/out ARCH=arm64 NAME=ironflockos-test-1.0.0 \
    IRONFLOCK_DL_BASE=https://dl.test IRONFLOCK_VERSION=2.0.1 \
    IRONFLOCK_KEYRING_SHA256=$(sha256sum "$key" | cut -d' ' -f1)
}

teardown() { rm -rf "$tmp"; }

# publish ARCH VERSION RECORD: a fake ironflock in cli/linux/ARCH/VERSION/ with
# its signature. Its bake records its arguments, installs itself as
# /usr/bin/ironflock and writes RECORD as image.json.
publish() {
  local d=$tmp/www/cli/linux/$1/$2
  mkdir -p "$d"
  cat >"$d/ironflock" <<EOF
#!/bin/bash
echo "\$*" >>"$tmp/bake-calls"
root=\$3
mkdir -p "\$root/usr/lib/ironflock" "\$root/usr/bin"
cp "\$0" "\$root/usr/bin/ironflock"
chmod 0755 "\$root/usr/bin/ironflock"
printf '%s\n' '$3' >"\$root/usr/lib/ironflock/image.json"
EOF
  echo good >"$d/ironflock.asc"
}

bake() { run env PATH="$tmp/bin:$PATH" bash "$bake"; }

@test "fetches ironflock of the pinned version and the image's architecture from cli/, checks it and bakes with it" {
  bake
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/curl-calls")" = "https://dl.test/cli/linux/arm64/2.0.1/ironflock
https://dl.test/cli/linux/arm64/2.0.1/ironflock.asc" ]
  [ "$(cat "$tmp/sqv-calls")" = "--keyring $(cd "$repo" && pwd)/profiles/base/keys/ironflock-bootstrap.asc $tmp/work/ironflock/ironflock.asc $tmp/work/ironflock/ironflock" ]
  [ "$(cat "$tmp/bake-calls")" = "bake --root $tmp/root --arch arm64 --download-base https://dl.test" ]
  [ -x "$tmp/root/usr/bin/ironflock" ]
  cmp "$tmp/root/usr/lib/ironflock/image.json" "$tmp/out/ironflockos-test-1.0.0.ironflock.json"
  [[ "$output" == *"ironflock 2.0.1 verified (signed by $fingerprint)"* ]]
  [[ "$output" == *"baked: agent 1.6.10, ironflock 2.0.1"* ]]
}

@test "a key file that is not the pinned one stops it before anything is downloaded" {
  IRONFLOCK_KEYRING_SHA256=0000000000000000000000000000000000000000000000000000000000000000 bake
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the pinned bootstrap key"* ]]
  [ ! -e "$tmp/curl-calls" ] && [ ! -e "$tmp/bake-calls" ]
}

@test "a download that is not signed by the bootstrap key is never run" {
  echo forged >"$tmp/www/cli/linux/arm64/2.0.1/ironflock.asc"
  bake
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://dl.test/cli/linux/arm64/2.0.1/ironflock is not signed by the IronFlock bootstrap key"* ]]
  [ ! -e "$tmp/bake-calls" ] && [ ! -e "$tmp/out/ironflockos-test-1.0.0.ironflock.json" ]
}

@test "a version or architecture that is not published stops it" {
  ARCH=amd64 bake
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot download https://dl.test/cli/linux/amd64/2.0.1/ironflock"* ]]
  [ ! -e "$tmp/bake-calls" ]
}

@test "an image.json without ironflock_version, or with another one, fails the build" {
  publish arm64 2.0.1 '{"agent_version": "1.6.9", "init_version": "1.4.10"}'
  bake
  [ "$status" -ne 0 ]
  [[ "$output" == *"image.json says ironflock_version '', the pin is 2.0.1"* ]]
  [ ! -e "$tmp/out/ironflockos-test-1.0.0.ironflock.json" ]
  publish arm64 2.0.1 '{"agent_version": "1.6.10", "ironflock_version": "2.0.0"}'
  bake
  [ "$status" -ne 0 ]
  [[ "$output" == *"image.json says ironflock_version '2.0.0'"* ]]
}

@test "an /usr/bin/ironflock that is not the verified download fails the build" {
  publish arm64 2.0.1 '{"agent_version": "1.6.10", "ironflock_version": "2.0.1"}'
  echo 'echo other >"$root/usr/bin/ironflock"' >>"$tmp/www/cli/linux/arm64/2.0.1/ironflock"
  bake
  [ "$status" -ne 0 ]
  [[ "$output" == *"/usr/bin/ironflock is not the verified download"* ]]
}

@test "profiles/base/versions pins ironflock and the bootstrap key file; nothing of ironflock-init is left" {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/profiles/base/versions"
  [[ "$IRONFLOCK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [ "$IRONFLOCK_KEYRING_SHA256" = "$(sha256sum "$key" | cut -d' ' -f1)" ]
  [ "$IRONFLOCK_DL_BASE" = https://instance-registry.ironflock.com/dl ]
  [ -z "$(grep -l 'DEVICE_INIT' "$repo/profiles/base/versions" "$bake")" ]
  [ -z "$(grep -rl 'ironflock-init' "$repo/build" "$repo/overlay" "$repo/profiles")" ]
}
