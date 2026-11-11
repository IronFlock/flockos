#!/usr/bin/env bats
# IronFlockOS on Compute Engine (ADR-0010): the .flock of a VM from its instance
# metadata (gce-flock against a stand-in metadata server), its unit, and the
# release's VM images (build/gce-image.sh against a stand-in gcloud).

repo="$BATS_TEST_DIRNAME/../.."
lib="$repo/overlay/usr/lib/ironflockos"
unit="$repo/overlay/usr/lib/systemd/system/ironflockos-gce-flock.service"
gce_image="$repo/build/gce-image.sh"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/esp" "$tmp/md/attributes"
}

teardown() {
  [ -z "${md_pid:-}" ] || kill "$md_pid" 2>/dev/null || true
  rm -rf "$tmp"
}

# metadata_server: a stand-in for the metadata server on 127.0.0.1. It
# answers only requests with Metadata-Flavor: Google, serves the files of
# md/attributes/ as instance attributes and, when md/guest/ exists, takes
# guest attributes into it (namespace_key); without it, guest attributes are
# off (404).
metadata_server() {
  cat >"$tmp/md.py" <<'EOF'
import http.server, os, sys
root, port_file = sys.argv[1], sys.argv[2]
ATTR = "/computeMetadata/v1/instance/attributes/"
GUEST = "/computeMetadata/v1/instance/guest-attributes/"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get("Metadata-Flavor") != "Google":
            return self.reply(403)
        path = os.path.join(root, "attributes", self.path[len(ATTR):])
        if self.path.startswith(ATTR) and os.path.isfile(path):
            return self.reply(200, open(path, "rb").read())
        self.reply(404)

    def do_PUT(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Metadata-Flavor") != "Google":
            return self.reply(403)
        guest = os.path.join(root, "guest")
        if not (self.path.startswith(GUEST) and os.path.isdir(guest)):
            return self.reply(404)
        open(os.path.join(guest, self.path[len(GUEST):].replace("/", "_")), "wb").write(body)
        self.reply(200)

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".part", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".part", port_file)
server.serve_forever()
EOF
  python3 -I "$tmp/md.py" "$tmp/md" "$tmp/port" >/dev/null 2>&1 3>&- &
  md_pid=$!
  for _ in $(seq 50); do
    [ -f "$tmp/port" ] && break
    sleep 0.1
  done
  [ -f "$tmp/port" ]
  export IRONFLOCKOS_METADATA="http://127.0.0.1:$(cat "$tmp/port")/computeMetadata/v1"
  export IRONFLOCKOS_ESP=$tmp/esp IRONFLOCKOS_GCE_TRIES=3 IRONFLOCKOS_GCE_DELAY=0
}

flock='{"device_key": 42, "secret": "s3cret", "name": "vm one"}'

@test "gce-flock puts the .flock of the metadata on the IRONFLOCKOS partition and reports it taken" {
  metadata_server
  printf '%s' "$flock" >"$tmp/md/attributes/ironflockos-flock"
  mkdir "$tmp/md/guest"
  run bash "$lib/gce-flock"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/esp/compute-engine.flock")" = "$flock" ]
  [ "$(ls -A "$tmp/esp")" = compute-engine.flock ]
  [ "$(cat "$tmp/md/guest/ironflockos_flock")" = taken ]
}

@test "enroll takes the .flock gce-flock left, like one put there by hand" {
  metadata_server
  printf '%s' "$flock" >"$tmp/md/attributes/ironflockos-flock"
  run bash "$lib/gce-flock"
  [ "$status" -eq 0 ]
  mkdir -p "$tmp/agent" "$tmp/state"
  printf '#!/bin/bash\necho "$*" >>%s/init-calls\n' "$tmp" >"$tmp/ironflock"
  chmod +x "$tmp/ironflock"
  IRONFLOCKOS_AGENT_DIR=$tmp/agent IRONFLOCKOS_STATE=$tmp/state IRONFLOCKOS_IRONFLOCK=$tmp/ironflock \
    IRONFLOCKOS_ENROLL_CONF=$tmp/enroll.conf run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  grep -qx "enroll -c $tmp/esp/compute-engine.flock --shred-source --hostname-from-flock" "$tmp/init-calls"
}

@test "gce-flock without the attribute leaves everything as it is" {
  metadata_server
  run bash "$lib/gce-flock"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no .flock in the instance metadata"* ]]
  [ -z "$(ls -A "$tmp/esp")" ]
}

@test "gce-flock refuses an attribute that is no .flock and leaves nothing behind" {
  metadata_server
  for bad in 'not json' '[]' '{"device_key": 42}'; do
    printf '%s' "$bad" >"$tmp/md/attributes/ironflockos-flock"
    run bash "$lib/gce-flock"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is no .flock"* ]]
    [ -z "$(ls -A "$tmp/esp")" ]
  done
}

@test "gce-flock on a VM without guest attributes keeps the .flock and says so" {
  metadata_server
  printf '%s' "$flock" >"$tmp/md/attributes/ironflockos-flock"
  run bash "$lib/gce-flock"
  [ "$status" -eq 0 ]
  [ -f "$tmp/esp/compute-engine.flock" ]
  [[ "$output" == *"ironflockos-flock stays in its metadata"* ]]
}

@test "gce-flock fails when the metadata server never answers, leaving nothing behind" {
  IRONFLOCKOS_METADATA=http://127.0.0.1:9/computeMetadata/v1 IRONFLOCKOS_ESP=$tmp/esp IRONFLOCKOS_GCE_TRIES=2 IRONFLOCKOS_GCE_DELAY=0 \
    run bash "$lib/gce-flock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not answer"* ]]
  [ -z "$(ls -A "$tmp/esp")" ]
}

@test "ironflockos-gce-flock.service: before the enrollment, on Compute Engine only, waiting for no network" {
  grep -qx 'Before=ironflockos-enroll.service' "$unit"
  grep -qx 'ConditionFirmware=smbios-field(product_name = "Google Compute Engine")' "$unit"
  grep -qx 'ConditionPathExists=!/var/lib/ironflockos/enrolled' "$unit"
  grep -qx 'ExecStart=/usr/lib/ironflockos/gce-flock' "$unit"
  # an offline device must not wait for the network before it enrolls
  ! grep -q 'network-online' "$unit"
  # every device image enables it
  grep -q 'ironflockos-enroll.service ironflockos-gce-flock.service ssh.service' "$repo/build/customize.sh"
}

@test "ironflockos-gce-flock.service: systemd understands its firmware condition" {
  command -v systemd-analyze >/dev/null || skip "no systemd-analyze"
  run systemd-analyze condition "$(grep '^ConditionFirmware=' "$unit")"
  # true on Compute Engine, false anywhere else, but never unparsable
  [[ "$output" =~ ConditionFirmware=smbios-field.*(succeeded|failed)\. ]] || {
    echo "$output"
    return 1
  }
}

# gce_env: a release image of IMAGE (default amd64-efi-base) in
# out/ironflockos-IMAGE/ with its SHA256SUMS, and a stand-in gcloud that records
# its calls, keeps what `storage cp` uploads, names an existing image's
# description in FAKE_EXISTING, and fails `images create` with
# FAKE_CREATE_EXIT.
gce_env() {
  image=${1:-amd64-efi-base}
  dir=$tmp/out/ironflockos-$image
  mkdir -p "$dir" "$tmp/bin" "$tmp/meta"
  head -c $((3 * 1024 * 1024)) /dev/urandom >"$tmp/raw"
  gzip -c "$tmp/raw" >"$dir/ironflockos-$image-1.2.3.img.gz"
  (cd "$dir" && sha256sum ironflockos-"$image"-1.2.3.img.gz) >"$tmp/meta/SHA256SUMS"
  cat >"$tmp/bin/gcloud" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$1 $2 $3" in
  "compute images describe")
    [ -n "${FAKE_EXISTING:-}" ] || exit 1
    echo "$FAKE_EXISTING"
    ;;
  "compute images create") exit "${FAKE_CREATE_EXIT:-0}" ;;
  "storage cp --quiet") cp "$4" "$FAKE_UPLOAD" ;;
esac
EOF
  chmod +x "$tmp/bin/gcloud"
  export PATH="$tmp/bin:$PATH" FAKE_LOG=$tmp/gcloud.log FAKE_UPLOAD=$tmp/upload.tar.gz IRONFLOCKOS_WORK=$tmp
}

# disk_size TARBALL: the size of the tarball's one member, disk.raw.
disk_size() {
  [ "$(tar -tzf "$1")" = disk.raw ]
  tar -tvzf "$1" | awk '{ print $3 }'
}

@test "gce-image: amd64-efi base from the published image, a disk of 10 GiB in its family" {
  gce_env
  run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -eq 0 ]
  # the image as disk.raw, grown to whole GiB, holes kept
  [ "$(disk_size "$tmp/upload.tar.gz")" = $((10 * 1024 * 1024 * 1024)) ]
  mkdir "$tmp/x"
  tar -xzf "$tmp/upload.tar.gz" -C "$tmp/x"
  cmp -n $((3 * 1024 * 1024)) "$tmp/raw" "$tmp/x/disk.raw"
  sha=$(sha256sum "$dir/ironflockos-amd64-efi-base-1.2.3.img.gz" | cut -d' ' -f1)
  gcs=gs://ironflock-downloads/staging/ironflockos/1.2.3/gce/ironflockos-amd64-efi-base-v1-2-3.tar.gz
  grep -qx "storage cp --quiet .*/ironflockos-amd64-efi-base-v1-2-3.tar.gz $gcs" "$tmp/gcloud.log"
  grep -q "^compute images create ironflockos-amd64-efi-base-v1-2-3 --project record-1283 --source-uri $gcs --family ironflockos-amd64-efi-base --architecture X86_64 --guest-os-features UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE --storage-location eu " "$tmp/gcloud.log"
  grep -q "^compute images create .* --description IronFlockOS 1.2.3 amd64-efi base for virtual devices: https://instance-registry.ironflock.com/dl/ironflockos/1.2.3/ironflockos-amd64-efi-base-1.2.3.img.gz sha256 $sha " "$tmp/gcloud.log"
  grep -q "^compute images create .* --labels ironflockos-version=1-2-3,ironflockos-target=amd64-efi,ironflockos-variant=base$" "$tmp/gcloud.log"
  # the tarball leaves the bucket again, and the scratch space
  [ "$(tail -n 1 "$tmp/gcloud.log")" = "storage rm --quiet $gcs" ]
  [ -z "$(find "$tmp" -maxdepth 1 -name 'gce-image.*')" ]
}

@test "gce-image: nvidia gets a disk for both of its 8 GiB slots, arm64-efi the arm64 machine" {
  gce_env amd64-efi-nvidia
  run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -eq 0 ]
  [ "$(disk_size "$tmp/upload.tar.gz")" = $((18 * 1024 * 1024 * 1024)) ]
  grep -q "^compute images create ironflockos-amd64-efi-nvidia-v1-2-3 .* --family ironflockos-amd64-efi-nvidia --architecture X86_64 " "$tmp/gcloud.log"

  rm -f "$tmp/gcloud.log"
  gce_env arm64-efi-base
  run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -eq 0 ]
  [ "$(disk_size "$tmp/upload.tar.gz")" = $((10 * 1024 * 1024 * 1024)) ]
  grep -q "^compute images create ironflockos-arm64-efi-base-v1-2-3 .* --family ironflockos-arm64-efi-base --architecture ARM64 --guest-os-features UEFI_COMPATIBLE,GVNIC --storage-location eu " "$tmp/gcloud.log"
}

@test "gce-image: only the published file becomes a VM image" {
  gce_env
  echo "0000000000000000000000000000000000000000000000000000000000000000  ironflockos-amd64-efi-base-1.2.3.img.gz" >"$tmp/meta/SHA256SUMS"
  run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the published file"* ]]
  [ ! -e "$tmp/gcloud.log" ]
  : >"$tmp/meta/SHA256SUMS"
  run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not in"* ]]
}

@test "gce-image: no VM image of a real-time kernel, the installer or the Pi" {
  gce_env
  for image in amd64-efi-base-rt amd64-efi-installer rpi-arm64-base; do
    mkdir -p "$tmp/out/ironflockos-$image"
    run bash "$gce_image" "$tmp/out/ironflockos-$image" 1.2.3
    [ "$status" -ne 0 ]
    [[ "$output" == *"has no Compute Engine image"* ]]
  done
  run bash "$gce_image" "$dir" v1.2.3
  [ "$status" -ne 0 ]
}

@test "gce-image: a re-run keeps the image made from the same file, refuses one from another" {
  gce_env
  sha=$(sha256sum "$dir/ironflockos-amd64-efi-base-1.2.3.img.gz" | cut -d' ' -f1)
  FAKE_EXISTING="IronFlockOS 1.2.3 amd64-efi base for virtual devices: … sha256 $sha" \
    run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exists, made from ironflockos-amd64-efi-base-1.2.3.img.gz: kept"* ]]
  ! grep -q 'images create\|storage cp' "$tmp/gcloud.log"
  FAKE_EXISTING="IronFlockOS 1.2.3 amd64-efi base for virtual devices: … sha256 0123" \
    run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"made from another file"* ]]
}

@test "gce-image: a failed creation still removes the tarball from the bucket" {
  gce_env
  FAKE_CREATE_EXIT=1 run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not make the image ironflockos-amd64-efi-base-v1-2-3"* ]]
  [[ "$(tail -n 1 "$tmp/gcloud.log")" == "storage rm --quiet gs://"*"/gce/ironflockos-amd64-efi-base-v1-2-3.tar.gz" ]]
}

@test "gce-image: a dry run makes the tarball and only prints the cloud calls" {
  gce_env
  DRY_RUN=1 run bash "$gce_image" "$dir" 1.2.3 "$tmp/meta/SHA256SUMS"
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/gcloud.log" ]
  [[ "$output" == *"ironflockos-amd64-efi-base-v1-2-3.tar.gz: a disk of 10 GiB"* ]]
  [[ "$output" == *"+ gcloud compute images create ironflockos-amd64-efi-base-v1-2-3 --project record-1283"* ]]
  [[ "$output" == *"dry run, nothing changed: would have made the image ironflockos-amd64-efi-base-v1-2-3"* ]]
}

@test "the VM images are images every release builds" {
  # shellcheck source=build/lib.sh
  . "$repo/build/lib.sh"
  load_conf "$repo/build/release.conf"
  [ -n "$GCE_IMAGES" ]
  for image in $GCE_IMAGES; do
    target=${image%-*} variant=${image##*-}
    grep -A2 -- "- target: $target\$" "$repo/.github/workflows/build.yml" |
      tr -s ' \n' '  ' | grep -q "variant: $variant kernel: std" || {
      echo "build.yml builds no $image"
      return 1
    }
  done
  # release.yml makes exactly these
  matrix=$(grep -E '^        image: \[' "$repo/.github/workflows/release.yml" | sed -E 's/.*\[(.*)\]/\1/; s/, */ /g')
  [ "$matrix" = "$GCE_IMAGES" ]
}
