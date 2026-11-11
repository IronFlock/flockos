#!/usr/bin/env bats
# The signed bundles against the keyring their images carry (ADR-0019,
# build/verify-bundles.sh), with stand-ins for rauc, sfdisk and debugfs: a
# stand-in disk image holds slot A with the keyring at the offset its
# partition table names, behind a decoy partition with another keyring; a
# stand-in bundle holds the certificate that signed it, and the stand-in rauc
# verifies it against the keyring with openssl, as the device would.

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
  stand_ins
  partitions rootfs-a
  export PATH="$tmp/bin:$PATH" IRONFLOCKOS_WORK="$tmp/work"
}

teardown() { rm -rf "$tmp"; }

# stand_ins: sfdisk --json DISK answers $tmp/sfdisk.json for a stand-in disk;
# debugfs -R "cat PATH" FS prints PATH of a stand-in file system (and, as
# debugfs does, reports a missing file on stderr only); rauc --conf=CONF info
# BUNDLE succeeds when the bundle's certificate chains to CONF's keyring and
# CONF has the device's keyring settings.
stand_ins() {
  cat >"$tmp/bin/sfdisk" <<STANDIN
#!/bin/bash
[ "\$1" = --json ] && [ -f "\$2" ] || exit 2
[ "\$(head -c 8 "\$2")" = "FAKE GPT" ] || { echo "sfdisk: \$2: no partition table" >&2; exit 1; }
cat "$tmp/sfdisk.json"
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
conf=${1#--conf=}
[ "$2" = info ] && [ -f "$3" ] || exit 2
grep -qx 'check-purpose=codesign' "$conf" && grep -qx 'use-bundle-signing-time=true' "$conf" ||
  { echo "stand-in rauc: not the device's keyring settings" >&2; exit 2; }
keyring=$(sed -n 's/^path=//p' "$conf")
[ "$(head -n 1 "$3")" = "FAKE RAUCB" ] || { echo "not a bundle" >&2; exit 1; }
sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$3" >"$conf.signer"
openssl verify -purpose any -CAfile "$keyring" "$conf.signer" >/dev/null 2>&1 ||
  { echo "signature verification failed" >&2; exit 1; }
echo "Compatible:     '$(sed -n 's/^compatible=//p' "$3")'"
STANDIN
  chmod +x "$tmp/bin/sfdisk" "$tmp/bin/debugfs" "$tmp/bin/rauc"
}

# partitions NAME...: the stand-in partition table: 512-byte sectors, the
# first partition (IRONFLOCKOS) at sector 4, 4 sectors long, the second (NAME)
# at sector 8, 16 sectors long.
partitions() {
  jq -n --arg second "$1" '{partitiontable: {label: "gpt", sectorsize: 512, partitions: [
    {node: "disk.img1", start: 4, size: 4, name: "IRONFLOCKOS"},
    {node: "disk.img2", start: 8, size: 16, name: $second}]}}' >"$tmp/sfdisk.json"
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

# fs [KEYRING]: a stand-in file system, with KEYRING as /etc/rauc/keyring.pem.
fs() {
  echo "FAKE EXT4"
  echo "== /etc/os-release"
  echo "ID=ironflockos"
  if [ -n "${1:-}" ]; then
    echo "== /etc/rauc/keyring.pem"
    cat "$1"
  fi
}

# image [KEYRING]: the disk image of $id: the decoy IRONFLOCKOS partition
# holds a file system with the other CA, slot A one with KEYRING.
image() {
  {
    echo "FAKE GPT" | pad 2048
    fs "$tmp/other/keyring.pem" | pad 2048
    fs "${1:-}" | pad 8192
  } | gzip -c >"$tmp/out/$id/$name.img.gz"
}

# bundle CERT: the bundle of $id, signed by CERT.
bundle() {
  { echo "FAKE RAUCB" && echo "compatible=$id" && cat "$1"; } >"$tmp/out/$id/$name.raucb"
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
    run bash "$verify" "$mode" "$tmp/out"
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

@test "dry run: the image refuses the stand-in's bundle and accepts the bundle signer" {
  image "$root_ca"
  bundle "$tmp/standin/signer.pem"
  run bash "$verify" dry-run "$tmp/out"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused by the keyring of $name.img.gz (CN=IronFlockOS root CA,O=IronFlock), which accepts the bundle signer"* ]]
  # a dry-run bundle the image would install
  bundle "$signer"
  run bash "$verify" dry-run "$tmp/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"signed by the dry-run stand-in, verifies against the keyring of $name.img.gz"* ]]
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
  mounts=$(grep -o -- '-v "[^"]*"' <<<"$checks" | sort)
  [ "$mounts" = "$(printf '%s\n' '-v "$out:/out:ro"' '-v "$repo/build/lib.sh:/src/build/lib.sh:ro"' \
    '-v "$repo/build/verify-bundles.sh:/src/build/verify-bundles.sh:ro"' '-v "$repo/pki:/src/pki:ro"' | sort)" ] ||
    { echo "$mounts"; return 1; }
  # ... and the script reads nothing else of it: lib.sh, and pki/ through $src
  [ "$(grep -o '"\$\(src\|here\)"[^ )]*\|\$\(src\|here\)/[^" )]*' "$repo/build/verify-bundles.sh" | sort -u | tr '\n' ' ')" = \
    '"$src"/pki/ironflockos-bundle-signer-*.pem $here/.. $here/lib.sh ' ]
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
