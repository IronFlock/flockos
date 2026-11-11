#!/usr/bin/env bats
# The signed bundles against the keyring their images carry (ADR-0019,
# build/verify-bundles.sh), with stand-ins for rauc, sfdisk and debugfs: a
# stand-in disk image holds slot A with the keyring and the image's RAUC
# system.conf at the offset its partition table names, behind a decoy
# partition with another keyring; a stand-in bundle holds the certificate
# that signed it, and the stand-in rauc verifies it against the keyring its
# configuration names with openssl, as the device would.

repo="$BATS_TEST_DIRNAME/../.."
verify="$repo/build/verify-bundles.sh"
root_ca="$repo/pki/ironflockos-root-ca.pem"
signer=$(printf '%s\n' "$repo"/pki/ironflockos-bundle-signer-*.pem | sort -V | tail -n 1)
id=ironflockos-amd64-efi-base
name=$id-1.0.0

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/out/$id" "$tmp/work"
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  # Another CA, and the dry run's stand-in signer.
  throwaway_signer "$tmp/other" "other"
  throwaway_signer "$tmp/standin" "IronFlockOS release dry run"
  export STANDIN=$tmp
  stand_ins
  partitions rootfs-a
  export PATH="$tmp/bin:$PATH" IRONFLOCKOS_WORK="$tmp/work"
}

teardown() { rm -rf "$tmp"; }

# stand_ins: sfdisk --json DISK answers $STANDIN/sfdisk.json for a stand-in
# disk; debugfs -R "cat PATH" FS prints PATH of a stand-in file system (and,
# as debugfs does, reports a missing file on stderr only). rauc --conf=CONF
# info BUNDLE succeeds when the bundle's certificate chains to CONF's keyring
# and CONF has the device's keyring settings, and otherwise fails with rauc's
# signature error; rauc --conf=CONF resign ... IN OUT checks IN so, writes OUT
# with the certificate of --cert= and checks it against --signing-keyring=.
# rauc appends each CONF to $STANDIN/rauc.confs. With $STANDIN/rauc.broken it
# fails at once, with $STANDIN/rauc.odd it refuses with another error.
stand_ins() {
  cat >"$tmp/bin/sfdisk" <<'STANDIN'
#!/bin/bash
[ "$1" = --json ] && [ -f "$2" ] || exit 2
[ "$(head -c 8 "$2")" = "FAKE GPT" ] || { echo "sfdisk: $2: no partition table" >&2; exit 1; }
cat "$STANDIN/sfdisk.json"
STANDIN
  cat >"$tmp/bin/debugfs" <<'STANDIN'
#!/bin/bash
[ "$1" = -R ] && [ "${2%% *}" = cat ] || exit 2
path=${2#cat } fs=$3
if [ "$(head -n 1 "$fs" | tr -d '\0')" != "FAKE EXT4" ]; then
  echo "debugfs: Bad magic number in super-block while trying to open $fs" >&2
  exit 1
fi
# The file system ends where the next one begins.
files=$(tr -s '\0' '\n' <"$fs" | awk 'NR > 1 && /^FAKE / { exit } { print }')
awk -v p="== $path" '$0 == p { f = 1; next } /^== / { f = 0 } f' <<<"$files"
grep -qx -- "== $path" <<<"$files" || echo "$path: File not found by ext2_lookup" >&2
STANDIN
  cat >"$tmp/bin/rauc" <<'STANDIN'
#!/bin/bash
conf=${1#--conf=} cmd=$2
shift 2
cat "$conf" >>"$STANDIN/rauc.confs"
if [ -e "$STANDIN/rauc.broken" ]; then
  echo "rauc: error while loading shared libraries: libcrypto.so.3" >&2
  exit 127
fi
grep -qx 'check-purpose=codesign' "$conf" && grep -qx 'use-bundle-signing-time=true' "$conf" ||
  { echo "stand-in rauc: not the device's keyring settings" >&2; exit 2; }
# verify KEYRING BUNDLE
verify() {
  [ "$(head -n 1 "$2")" = "FAKE RAUCB" ] || { echo "not a bundle" >&2; return 1; }
  sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$2" >"$conf.signer"
  openssl verify -purpose any -CAfile "$1" "$conf.signer" >/dev/null 2>&1 && return 0
  if [ -e "$STANDIN/rauc.odd" ]; then
    echo "Failed to open bundle: unsupported bundle format" >&2
  else
    echo "Failed to verify bundle signature: signature verification failed: unable to get local issuer certificate" >&2
  fi
  return 1
}
keyring=$(sed -n 's/^path=//p' "$conf")
case "$cmd" in
  info)
    [ -f "$1" ] || exit 2
    verify "$keyring" "$1" || exit 1
    echo "Compatible:     '$(sed -n 's/^compatible=//p' "$1")'"
    ;;
  resign)
    files=()
    for a in "$@"; do
      case "$a" in --signing-keyring=*) signing=${a#*=} ;; --cert=*) cert=${a#*=} ;; --key=*) ;; *) files+=("$a") ;; esac
    done
    verify "$keyring" "${files[0]}" || exit 1
    { head -n 2 "${files[0]}" && cat "$cert"; } >"${files[1]}"
    verify "$signing" "${files[1]}" || exit 1
    ;;
  *) exit 2 ;;
esac
STANDIN
  chmod +x "$tmp/bin/sfdisk" "$tmp/bin/debugfs" "$tmp/bin/rauc"
}

# partitions NAME...: the stand-in partition table: 512-byte sectors, the
# first partition (IRONFLOCKOS) at sector 4, 4 sectors long, the second (NAME)
# at sector 8, 32 sectors long.
partitions() {
  jq -n --arg second "$1" '{partitiontable: {label: "gpt", sectorsize: 512, partitions: [
    {node: "disk.img1", start: 4, size: 4, name: "IRONFLOCKOS"},
    {node: "disk.img2", start: 8, size: 32, name: $second}]}}' >"$STANDIN/sfdisk.json"
}

# system_conf [COMPATIBLE]: the image's /etc/rauc/system.conf as the build
# renders it (targets/amd64-efi/system.conf).
system_conf() {
  sed "s/@COMPATIBLE@/${1:-$id}/" "$repo/targets/amd64-efi/system.conf"
}

# pad BYTES: stdin, padded with zeros to BYTES (and no longer).
pad() {
  local f
  f=$(mktemp "$tmp/pad.XXXXXX")
  cat >"$f"
  [ "$(wc -c <"$f")" -le "$1" ] || { echo "the stand-in does not fit $1 bytes" >&2; return 1; }
  truncate -s "$1" "$f"
  cat "$f"
}

# fs [KEYRING [SYSTEM_CONF]]: a stand-in file system, with KEYRING as
# /etc/rauc/keyring.pem and SYSTEM_CONF (default: system_conf) as
# /etc/rauc/system.conf; "-" leaves either out.
fs() {
  local conf=${2:-}
  echo "FAKE EXT4"
  echo "== /etc/os-release"
  echo "ID=ironflockos"
  if [ -n "${1:-}" ] && [ "$1" != - ]; then
    echo "== /etc/rauc/keyring.pem"
    cat "$1"
  fi
  if [ "$conf" != - ]; then
    echo "== /etc/rauc/system.conf"
    if [ -n "$conf" ]; then cat "$conf"; else system_conf; fi
  fi
}

# image [KEYRING [SYSTEM_CONF]]: the disk image of $id: the decoy IRONFLOCKOS
# partition holds a file system with the other CA, slot A one with KEYRING
# and SYSTEM_CONF (fs).
image() {
  set -o pipefail
  {
    echo "FAKE GPT" | pad 2048
    fs "$tmp/other/keyring.pem" - | pad 2048
    fs "${1:-}" "${2:-}" | pad 16384
  } | gzip -c >"$tmp/out/$id/$name.img.gz"
}

# bundle CERT [COMPATIBLE]: the bundle of $id, signed by CERT.
bundle() {
  { echo "FAKE RAUCB" && echo "compatible=${2:-$id}" && cat "$1"; } >"$tmp/out/$id/$name.raucb"
}

@test "verify-bundles.sh needs a mode and a directory" {
  run bash "$verify"
  [ "$status" -ne 0 ] && [[ "$output" == *"usage"* ]]
  run bash "$verify" kms "$tmp/out"
  [ "$status" -ne 0 ] && [[ "$output" == *"usage"* ]]
  run bash "$verify" release "$tmp/missing"
  [ "$status" -ne 0 ] && [[ "$output" == *"no directory"* ]]
}

@test "release: the bundle verifies against the keyring in slot A of its image" {
  image "$root_ca"
  bundle "$signer"
  run bash "$verify" release "$tmp/out"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$name.raucb verifies against the keyring of $name.img.gz (CN=IronFlockOS root CA,O=IronFlock)"* ]]
  [[ "$output" == *"1 bundles checked"* ]]
  # nothing left in the scratch space
  [ -z "$(ls -A "$tmp/work")" ]
}

@test "release: a bundle the image's keyring refuses fails the run" {
  image "$root_ca"
  bundle "$tmp/standin/signer.pem"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$name.raucb does not verify against the keyring of $name.img.gz"* ]]
}

@test "an image that trusts another CA fails the run, in both modes" {
  # the bundle would verify against the IronFlockOS root CA; the image does not trust it
  image "$tmp/other/keyring.pem"
  bundle "$signer"
  for mode in release dry-run; do
    IRONFLOCKOS_STANDIN_KEYRING=$tmp/standin/keyring.pem run bash "$verify" "$mode" "$tmp/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"the keyring of $name.img.gz (CN=other CA (throwaway),O=IronFlock) does not accept the bundle signer"* ]]
  done
}

@test "an image without a keyring, or without slot A, fails the run" {
  image
  bundle "$signer"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$name.img.gz carries no RAUC keyring in slot A"* ]]
  [[ "$output" == *"File not found"* ]]
  image "$root_ca"
  partitions rootfs-b
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$name.img.gz has no single partition rootfs-a"* ]]
  # a bundle without its image
  rm "$tmp/out/$id/$name.img.gz"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no disk image next to it"* ]]
}

@test "the check takes the image's own RAUC settings: compatible, bundle formats, the keyring section" {
  image "$root_ca"
  bundle "$signer"
  run bash "$verify" release "$tmp/out"
  [ "$status" -eq 0 ]
  # what rauc got: the image's compatible and formats, its keyring settings
  # with the keyring read from the image, and none of its slots or bootloader
  conf=$(sed 's|^path=.*/keyring.pem$|path=KEYRING|' "$STANDIN/rauc.confs")
  [ "$conf" = "$(printf '%s\n' '[system]' "compatible=$id" bootloader=noop bundle-formats=verity '' \
    '[keyring]' path=KEYRING use-bundle-signing-time=true check-purpose=codesign)" ] || { echo "$conf"; return 1; }
  # a setting the image adds goes along
  system_conf | sed 's/^check-purpose=codesign$/&\nallow-partial-chain=true/' >"$tmp/partial.conf"
  image "$root_ca" "$tmp/partial.conf"
  : >"$STANDIN/rauc.confs"
  run bash "$verify" release "$tmp/out"
  [ "$status" -eq 0 ]
  grep -qx allow-partial-chain=true "$STANDIN/rauc.confs"
}

@test "an image without system.conf, of another compatible, or with a keyring directory fails the run" {
  bundle "$signer"
  image "$root_ca" -
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$name.img.gz carries no RAUC system.conf with a keyring in slot A"* ]]
  system_conf ironflockos-amd64-efi-nvidia >"$tmp/other.conf"
  image "$root_ca" "$tmp/other.conf"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$name.img.gz is compatible ironflockos-amd64-efi-nvidia, not $id"* ]]
  system_conf | sed 's|^path=.*|directory=/etc/rauc/certs|' >"$tmp/dir.conf"
  image "$root_ca" "$tmp/dir.conf"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no single keyring path, or a keyring directory"* ]]
  # a keyring path other than the file the check reads: the device would
  # check its updates with a keyring the check never saw
  system_conf | sed 's|^path=.*|path=/etc/rauc/other-ca.pem|' >"$tmp/path.conf"
  image "$root_ca" "$tmp/path.conf"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"or a keyring other than /etc/rauc/keyring.pem"* ]]
  # a bundle for another image, which the device would refuse to install
  image "$root_ca"
  bundle "$signer" ironflockos-amd64-efi-nvidia
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$name.raucb is not compatible $id, as its image is"* ]]
}

@test "dry run: the bundle verifies with the stand-in's CA, the image's keyring refuses it by its signature, and accepts the bundle signer" {
  image "$root_ca"
  bundle "$tmp/standin/signer.pem"
  IRONFLOCKOS_STANDIN_KEYRING=$tmp/standin/keyring.pem run bash "$verify" dry-run "$tmp/out"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verifies with the stand-in's CA and is refused by the signature check against the keyring of $name.img.gz (CN=IronFlockOS root CA,O=IronFlock), which accepts the bundle signer"* ]]
  # the positive control ran with the image's settings and the stand-in's CA
  grep -qx "path=$tmp/standin/keyring.pem" "$STANDIN/rauc.confs"
  [ "$(grep -c '^bundle-formats=verity$' "$STANDIN/rauc.confs")" = 2 ]
  # a dry-run bundle the image would install (here a stand-in that is the
  # root CA)
  bundle "$signer"
  IRONFLOCKOS_STANDIN_KEYRING=$root_ca run bash "$verify" dry-run "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"signed by the dry-run stand-in, verifies against the keyring of $name.img.gz"* ]]
}

@test "dry run: no stand-in CA, a rauc that cannot verify, or a refusal for another reason fails the run" {
  image "$root_ca"
  bundle "$tmp/standin/signer.pem"
  # without the stand-in's CA there is no positive control
  run bash "$verify" dry-run "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"a dry run needs the stand-in's CA"* ]]
  IRONFLOCKOS_STANDIN_KEYRING=$tmp/missing.pem run bash "$verify" dry-run "$tmp/out"
  [ "$status" -ne 0 ]
  # a rauc that fails whatever it gets: the refusal would mean nothing
  touch "$STANDIN/rauc.broken"
  IRONFLOCKOS_STANDIN_KEYRING=$tmp/standin/keyring.pem run bash "$verify" dry-run "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not verify against the dry run's stand-in CA, in the positive control: the check cannot work here"* ]]
  rm "$STANDIN/rauc.broken"
  # refused, but not by the signature check
  touch "$STANDIN/rauc.odd"
  IRONFLOCKOS_STANDIN_KEYRING=$tmp/standin/keyring.pem run bash "$verify" dry-run "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is refused with the keyring of $name.img.gz, but not by rauc's signature check"* ]]
  [[ "$output" == *"unsupported bundle format"* ]]
  # and in a release, a rauc that cannot verify fails it too
  rm "$STANDIN/rauc.odd"
  touch "$STANDIN/rauc.broken"
  bundle "$signer"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
}

@test "sign-bundles.sh, dry run: the stand-in's CA goes only where IRONFLOCKOS_STANDIN_KEYRING says, never into DIR" {
  export IRONFLOCKOS_HOST_UID IRONFLOCKOS_HOST_GID
  IRONFLOCKOS_HOST_UID=$(id -u) IRONFLOCKOS_HOST_GID=$(id -g)
  # a release build's image: the bundle sealed with the build's throwaway key
  throwaway_signer "$tmp/seal" "IronFlockOS release sealing"
  image "$root_ca"
  bundle "$tmp/seal/signer.pem"
  cp "$tmp/seal/keyring.pem" "$tmp/out/$id/$name.seal-ca.pem"
  mkdir "$tmp/handover"
  # inside DIR it refuses, before it signs anything
  IRONFLOCKOS_STANDIN_KEYRING=$tmp/out/$id/standin.pem run bash "$repo/build/sign-bundles.sh" dry-run "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must lie outside"* ]]
  [ ! -e "$tmp/out/$id/standin.pem" ]
  cmp -s <(sed -n '/BEGIN/,/END/p' "$tmp/out/$id/$name.raucb") "$tmp/seal/signer.pem"
  # outside it
  IRONFLOCKOS_STANDIN_KEYRING=$tmp/handover/standin-ca.pem run bash "$repo/build/sign-bundles.sh" dry-run "$tmp/out"
  echo "$output"
  [ "$status" -eq 0 ]
  # DIR holds the image's files and nothing of the stand-in's CA
  [ "$(ls "$tmp/out/$id" | sort | tr '\n' ' ')" = "SHA256SUMS $name.img.gz $name.raucb " ]
  ca_body=$(grep -v -- '-----' "$tmp/handover/standin-ca.pem" | tr -d '\n')
  [ -n "$ca_body" ]
  ! grep -rqF "$(head -c 64 <<<"$ca_body")" "$tmp/out"
  # the bundle is the stand-in's, which that CA accepts and the root CA does not
  sed -n '/BEGIN/,/END/p' "$tmp/out/$id/$name.raucb" >"$tmp/signed.pem"
  openssl verify -purpose any -CAfile "$tmp/handover/standin-ca.pem" "$tmp/signed.pem"
  ! openssl verify -purpose any -CAfile "$root_ca" "$tmp/signed.pem" 2>/dev/null
  # and the check passes on what sign-bundles.sh left
  IRONFLOCKOS_STANDIN_KEYRING=$tmp/handover/standin-ca.pem run bash "$verify" dry-run "$tmp/out"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the installer has no bundle; a directory without any bundle fails" {
  image "$root_ca"
  bundle "$signer"
  mkdir -p "$tmp/out/ironflockos-amd64-efi-installer"
  echo stick | gzip -c >"$tmp/out/ironflockos-amd64-efi-installer/ironflockos-amd64-efi-installer-1.0.0.img.gz"
  run bash "$verify" release "$tmp/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 bundles checked"* ]]
  rm -r "$tmp/out/$id"
  run bash "$verify" release "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no bundles"* ]]
}

@test "the sign job checks every bundle against its image's keyring before anything is published" {
  sib="$repo/build/sign-in-builder.sh"
  # two containers: sign-bundles.sh, then verify-bundles.sh
  [ "$(grep -c '^docker run ' "$sib")" = 2 ]
  signs=$(awk '/^docker run / { n++ } n == 1' "$sib")
  checks=$(awk '/^docker run / { n++ } n == 2' "$sib")
  [[ "$signs" == *'exec bash /src/build/sign-bundles.sh "$1" /out'* ]]
  [[ "$checks" == *'exec bash /src/build/verify-bundles.sh "$1" /out'* ]]
  # the check, which reads the images' file systems, gets neither the
  # release identity nor write access to the images
  [[ "$signs" == *'${creds[@]+"${creds[@]}"}'* ]]
  [[ "$checks" != *creds* && "$checks" != *GOOGLE* ]]
  [[ "$checks" == *'-v "$out:/out:ro"'* ]]
  # Of the repository it gets only what it reads, never the whole working
  # tree: google-github-actions/auth leaves the release identity's
  # credentials file (gha-creds-*.json) there.
  [[ "$checks" != *'"$repo:'* && "$checks" != *'$GITHUB_WORKSPACE'* ]]
  # ... and by no other way to mount than the -v arguments counted below
  [[ "$checks" != *--mount* && "$checks" != *--volumes-from* && "$checks" != *--volume* ]]
  mounts=$(grep -o -- '-v "[^"]*"' <<<"$checks" | sort)
  [ "$mounts" = "$(printf '%s\n' '-v "$out:/out:ro"' '-v "$repo/build/lib.sh:/src/build/lib.sh:ro"' \
    '-v "$repo/build/verify-bundles.sh:/src/build/verify-bundles.sh:ro"' '-v "$repo/pki:/src/pki:ro"' | sort)" ] ||
    { echo "$mounts"; return 1; }
  # ... and the script reads nothing else of it: lib.sh, and pki/ through $src
  [ "$(grep -o '"\$\(src\|here\)"[^ )]*\|\$\(src\|here\)/[^" )]*' "$repo/build/verify-bundles.sh" | sort -u | tr '\n' ' ')" = \
    '"$src"/pki/ironflockos-bundle-signer-*.pem $here/.. $here/lib.sh ' ]
  # a dry run hands the stand-in's CA over outside DIR: written by the
  # signing container, read-only for the check, removed at the end
  [[ "$signs" == *'${handover_rw[@]+"${handover_rw[@]}"}'* ]]
  [[ "$checks" == *'${handover_ro[@]+"${handover_ro[@]}"}'* ]]
  grep -q '^  handover=$(mktemp -d "${TMPDIR:-/tmp}/ironflockos-standin.XXXXXX")$' "$sib"
  grep -q "^  trap 'rm -rf \"\$handover\"' EXIT$" "$sib"
  grep -q '^  handover_rw=(-v "$handover:/handover" -e IRONFLOCKOS_STANDIN_KEYRING=/handover/standin-ca.pem)$' "$sib"
  grep -q '^  handover_ro=(-v "$handover:/handover:ro" -e IRONFLOCKOS_STANDIN_KEYRING=/handover/standin-ca.pem)$' "$sib"
  # every apt-get of both containers with a time limit
  [ "$(grep -v '^#' "$sib" | grep -c 'apt-get')" = 4 ]
  [ "$(grep -c '^    timeout -k 30s 5m apt-get ' "$sib")" = 4 ]
  # with the tools it needs, and its scratch space
  packages=$(grep -A1 'install --no-install-recommends' <<<"$checks" | tail -n 1)
  for pkg in rauc openssl e2fsprogs fdisk jq; do [[ " $packages " == *" $pkg "* ]] || { echo "$pkg: $packages"; return 1; }; done
  [[ "$checks" == *'${scratch[@]+"${scratch[@]}"}'* ]]
  # release.yml's sign job runs it on the runner's second disk; stage needs sign
  wf=$repo/.github/workflows/release.yml
  sign=$(awk '$0 == "  sign:" { f = 1; next } f && /^  [a-z][a-z-]*:$/ { exit } f' "$wf")
  [[ "$sign" == *'IRONFLOCKOS_WORK: /mnt/ironflockos-sign'* ]]
  [[ "$sign" == *'build/sign-in-builder.sh "$MODE" out'* ]]
  [[ "$(awk '$0 == "  stage:" { f = 1; next } f && /^    needs:/ { print; exit }' "$wf")" == *sign* ]]
}
