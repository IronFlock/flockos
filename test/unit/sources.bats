#!/usr/bin/env bats
# The source code of a release (docs/release.md, "Source code"): the source
# packages an image records (build/sources.sh image), the plan for the ones
# outside the archives (release/sources), the index SOURCES, and what
# build/publish.sh sources uploads where (dry runs). apt's lookup in the
# build container runs in the release's sources job.

repo="$BATS_TEST_DIRNAME/../.."
sources="$repo/build/sources.sh"
publish="$repo/build/publish.sh"

setup() { tmp=$(mktemp -d); }
teardown() { rm -rf "$tmp"; }

@test "image: each package's source and the ones its Built-Using names, once each, sorted" {
  run bash "$sources" image <<'EOF'
linux-signed-amd64	6.12.115+2	linux (= 6.12.115-2)
linux-signed-amd64	6.12.115+2	linux (= 6.12.115-2)
grub-efi-amd64-signed	1+2.12+9+deb13u2	grub2 (= 2.12-9+deb13u2)
bash	5.2.37-2
flockos-nvidia-modules	620.70.06-1
gcc-14	14.2.0-19	gcc-14 (= 14.2.0-19), binutils (= 2.44-3),
 glibc (= 2.41-12)
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    'bash	5.2.37-2' \
    'binutils	2.44-3' \
    'flockos-nvidia-modules	620.70.06-1' \
    'gcc-14	14.2.0-19' \
    'glibc	2.41-12' \
    'grub-efi-amd64-signed	1+2.12+9+deb13u2' \
    'grub2	2.12-9+deb13u2' \
    'linux	6.12.115-2' \
    'linux-signed-amd64	6.12.115+2')" ]
}

@test "image: refuses what is not a source line or a Built-Using entry" {
  run bash "$sources" image <<<"bash"
  [ "$status" -ne 0 ]
  run bash "$sources" image <<<"$(printf 'x\t1\tlinux (>= 6.0)')"
  [ "$status" -ne 0 ]
}

@test "plan: release/sources decides for the packages outside the archives, without apt" {
  printf '%s\t%s\n' docker-ce '5:29.9.3-1~debian.13~trixie' nvidia-modprobe 620.70.06-1 \
    flockos-nvidia-modules 620.70.06-1 >"$tmp/list"
  run bash "$sources" plan "$tmp/list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker-ce	5:29.9.3-1~debian.13~trixie	-	-	-	Apache-2.0"* ]]
  [[ "$output" == *"nvidia-modprobe	620.70.06-1	upstream/nvidia-modprobe/nvidia-modprobe_620.70.06.tar.gz	https://github.com/NVIDIA/nvidia-modprobe/archive/refs/tags/620.70.06.tar.gz	-	-"* ]]
  [[ "$output" == *"flockos-nvidia-modules	620.70.06-1	upstream/flockos-nvidia-modules/flockos-nvidia-modules_620.70.06.tar.gz	https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/620.70.06.tar.gz"* ]]
}

@test "plan: refuses an empty list and a line that is no source package" {
  : >"$tmp/list"
  run bash "$sources" plan "$tmp/list"
  [ "$status" -ne 0 ]
  printf '../x\t1.0\n' >"$tmp/list"
  run bash "$sources" plan "$tmp/list"
  [ "$status" -ne 0 ]
}

@test "release/sources: every line is upstream with an https URL or none with a reason" {
  run awk '!/^[ \t]*(#|$)/ && !($2 == "upstream" && $3 ~ /^https:\/\/[^ ]*\{upstream\}[^ ]*$/ && NF == 3) && !($2 == "none" && NF >= 3) { print FILENAME ":" FNR ": " $0 }' \
    "$repo/release/sources"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# plan: a plan of each kind of line.
plan() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    acl 2.3.2-2 debian/acl/acl_2.3.2-2.dsc http://deb.debian.org/debian/pool/main/a/acl/acl_2.3.2-2.dsc SHA256:1f42 - \
    acl 2.3.2-2 debian/acl/acl_2.3.2.orig.tar.xz http://deb.debian.org/debian/pool/main/a/acl/acl_2.3.2.orig.tar.xz SHA256:9720 - \
    linux 1:6.18.60-1+rpt1 raspberrypi/linux/linux_6.18.60-1+rpt1.dsc https://archive.raspberrypi.com/debian/pool/main/l/linux/linux_6.18.60-1+rpt1.dsc SHA256:aa - \
    nvidia-modprobe 620.70.06-1 upstream/nvidia-modprobe/nvidia-modprobe_620.70.06.tar.gz https://github.com/NVIDIA/nvidia-modprobe/archive/refs/tags/620.70.06.tar.gz - - \
    docker-ce 5:29.9.3-1~debian.13~trixie - - - 'Apache-2.0 (https://github.com/docker/docker-ce-packaging)'
}

@test "index: the release's SOURCES, every file under DL_BASE/flockos/sources/ and a reason for the rest" {
  plan >"$tmp/plan"
  run bash "$sources" index "$tmp/plan" 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == "# FlockOS 1.2.3: the source code"* ]]
  [[ "$output" == *"https://github.com/IronFlock/ironflockos at the tag"*"v1.2.3"* ]]
  [[ "$output" == *$'\nacl\t2.3.2-2\thttps://instance-registry.ironflock.com/dl/flockos/sources/debian/acl/acl_2.3.2-2.dsc\n'* ]]
  [[ "$output" == *$'linux\t1:6.18.60-1+rpt1\thttps://instance-registry.ironflock.com/dl/flockos/sources/raspberrypi/linux/linux_6.18.60-1+rpt1.dsc'* ]]
  [[ "$output" == *$'docker-ce\t5:29.9.3-1~debian.13~trixie\t-\tApache-2.0'* ]]
  [ "$(grep -vc '^#' <<<"$output")" = 5 ]
}

@test "publish.sh sources: the files to the pool without replacing any, SOURCES to the staging tree (dry run)" {
  plan >"$tmp/plan"
  DRY_RUN=1 run bash "$publish" sources "$tmp/plan" 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ gcloud storage cp --recursive --no-clobber"*" gs://ironflock-downloads/flockos/sources/"* ]]
  [[ "$output" == *"+ gcloud storage cp --quiet --cache-control=public, max-age=0 "*" gs://ironflock-downloads/staging/flockos/1.2.3/SOURCES"* ]]
  [[ "$output" == *"would have uploaded 4 of the release's 4 source files"* ]]
}

@test "publish.sh sources: refuses a path outside the pool" {
  plan >"$tmp/plan"
  printf 'x\t1\tdebian/x/../../manifest.json\thttp://deb.debian.org/x\tSHA256:00\t-\n' >>"$tmp/plan"
  DRY_RUN=1 run bash "$publish" sources "$tmp/plan" 1.2.3
  [ "$status" -ne 0 ]
}

@test "publish.sh sources: a file two source versions share is uploaded once" {
  plan >"$tmp/plan"
  printf 'acl\t2.3.2-3\tdebian/acl/acl_2.3.2.orig.tar.xz\thttps://snapshot.debian.org/file/9720\tSHA1:9720\t-\n' >>"$tmp/plan"
  DRY_RUN=1 run bash "$publish" sources "$tmp/plan" 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"would have uploaded 4 of the release's 4 source files"* ]]
}

# stand_ins POOL_FILE: gcloud that logs its calls to $tmp/log and lists
# POOL_FILE (if any) in the pool, and curl that writes each URL as the file's
# content.
stand_ins() {
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/gcloud" <<EOF
#!/bin/bash
echo "gcloud \$*" >>"$tmp/log"
if [ "\$1 \$2" = "storage ls" ] && [ -n "$1" ]; then echo "gs://ironflock-downloads/flockos/sources/$1"; fi
exit 0
EOF
  cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; http*) url=$1 ;; esac; shift; done
printf '%s' "$url" >"$out"
EOF
  chmod +x "$tmp/bin/gcloud" "$tmp/bin/curl"
}

# fileplan [HASH]: two files of acl, each with the hash of its URL (or HASH).
fileplan() {
  local f url
  for f in acl_2.3.2-2.dsc acl_2.3.2.orig.tar.xz; do
    url=http://deb.debian.org/debian/pool/main/a/acl/$f
    printf 'acl\t2.3.2-2\tdebian/acl/%s\t%s\tSHA256:%s\t-\n' "$f" "$url" "${1:-$(printf '%s' "$url" | sha256sum | cut -d ' ' -f 1)}"
  done
}

@test "publish.sh sources: downloads what the pool lacks, checks its hash, uploads it without replacing" {
  stand_ins debian/acl/acl_2.3.2-2.dsc
  fileplan >"$tmp/plan"
  run env PATH="$tmp/bin:$PATH" bash "$publish" sources "$tmp/plan" 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"uploaded 1 of the release's 2 source files"* ]]
  [ "$(grep -c 'storage cp --recursive --no-clobber' "$tmp/log")" = 1 ]
  grep -q 'staging/flockos/1.2.3/SOURCES' "$tmp/log"
}

@test "publish.sh sources: an empty pool gets every file" {
  stand_ins ""
  fileplan >"$tmp/plan"
  run env PATH="$tmp/bin:$PATH" bash "$publish" sources "$tmp/plan" 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"uploaded 2 of the release's 2 source files"* ]]
}

@test "publish.sh sources: a file with another hash than the plan's fails before any upload" {
  stand_ins ""
  fileplan 0000 >"$tmp/plan"
  run env PATH="$tmp/bin:$PATH" bash "$publish" sources "$tmp/plan" 1.2.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the file the plan names"* ]]
  ! grep -q 'storage cp' "$tmp/log"
}

@test "every image records its source packages, and the nvidia modules carry their licence" {
  grep -q 'source:Package.*source:Version.*Built-Using' "$repo/build/customize.sh"
  grep -q 'sources.sh" image >"$OUT/$NAME.sources.tsv"' "$repo/build/customize.sh"
  grep -q 'cp /usr/share/doc/nvidia-kernel-open-dkms/copyright "$doc/copyright"' "$repo/build/nvidia-modules.sh"
}

@test "the image's copyright file: FlockOS's own files under Apache-2.0, and where SOURCES is" {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/build/release.conf"
  f="$repo/overlay/usr/share/doc/flockos/copyright"
  grep -q '^Copyright 2026 IronFlock GmbH$' "$f"
  grep -q '/usr/share/common-licenses/Apache-2.0' "$f"
  grep -qF "$DL_BASE/flockos/<VERSION_ID>/SOURCES" "$f"
}
