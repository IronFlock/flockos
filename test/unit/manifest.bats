#!/usr/bin/env bats
# The release manifest contract (ADR-0009, docs/manifest.schema.json): the
# example document is consistent between what the device-agent reads
# (channels, releases, images) and what FlockFlasher reads (boards), and both
# keep the fields the readers' types have today.

repo="$BATS_TEST_DIRNAME/../.."
schema="$repo/docs/manifest.schema.json"
example="$repo/docs/manifest.example.json"

@test "schema and example are JSON" {
  jq -e . "$schema" >/dev/null
  jq -e . "$example" >/dev/null
  [ "$(jq -r .schema "$example")" = "$(jq -r .properties.schema.const "$schema")" ]
}

@test "the schema keeps every field of FlockFlasher's SupportedBoard and ImageInfo" {
  # flasher src/types/index.ts
  for f in architecture board docs reflasher boardname cpu latestImages model modelname; do
    jq -e --arg f "$f" '."$defs".board.required | index($f)' "$schema" >/dev/null || { echo "board lacks $f"; return 1; }
  done
  for f in buildtime download file osname osvariant sha256 size update version; do
    jq -e --arg f "$f" '."$defs".imageInfo.required | index($f)' "$schema" >/dev/null || { echo "imageInfo lacks $f"; return 1; }
  done
}

@test "every channel names a release, and every release is named by a channel" {
  run jq -e '([.channels[]] | unique) == (.releases | keys | sort)' "$example"
  [ "$status" -eq 0 ]
}

@test "an image's key is its IMAGE_ID, which its bundle names as compatible" {
  run jq -r '.releases[].images | to_entries[] |
    .key as $id | .value as $i |
    ("flockos-" + $i.target + "-" + $i.variant + (if $i.kernel == "rt" then "-rt" else "" end)) as $want |
    select($id != $want or ($i.bundle != null and $i.bundle.compatible != $id)) | $id' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the installer has no bundle; every other image has one" {
  run jq -r '.releases[].images | to_entries[] |
    select((.value.variant == "installer") == (.value.bundle != null)) | .key' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the files are named <image-id>-<version> and served over https" {
  run jq -r '.releases | to_entries[] | .key as $v | .value.images | to_entries[] |
    .key as $id | .value as $i |
    select(($i.image.url | endswith("/" + $id + "-" + $v + ".img.gz") | not)
      or ($i.bundle != null and ($i.bundle.url | endswith("/" + $id + "-" + $v + ".raucb") | not))
      or ($i.image.url | startswith("https://") | not)) | $id' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "FlockFlasher's boards show the production release, as the agent's view has it" {
  run jq -r '.channels.production as $v | .releases[$v].images as $imgs |
    .boards[] | .board as $b | .latestImages[] |
    . as $e | $imgs[$e.image_id] as $i |
    select($i == null
      or $e.version != $v
      or $e.download != $i.image.url
      or $e.sha256 != $i.image.sha256
      or $e.size != $i.image.size
      or $e.update != ($i.bundle.url // "")
      or $e.file != ($e.download | split("/") | last)
      or $e.variant != $i.variant or $e.kernel != $i.kernel
      or $e.osvariant != "image") | "\($b): \($e.image_id)"' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a board lists its base image first (FlockFlasher before WP-2.7 takes the first)" {
  run jq -r '.boards[] | select(.latestImages[0].variant != "base") | .model' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the signed envelope stays below the device-agent's 64 KiB limit" {
  payload=$(jq -c . "$example" | base64 | tr -d '\n' | wc -c)
  # {"payload": "...", "signature": "<88 base64 characters>"} and indentation
  [ $((payload + 200)) -lt 65536 ]
}

@test "an installer's payloads are updatable images of its target in its release" {
  run jq -r '.releases | to_entries[] | .key as $v | .value.images as $imgs |
    $imgs | to_entries[] | .key as $id | .value as $i |
    if $i.variant == "installer" then
      ($i.payloads // [])[] | . as $p | $imgs[$p] as $pi |
      select($pi == null or $pi.target != $i.target or $pi.variant == "installer" or $pi.bundle == null) |
      "\($v) \($id): \($p)"
    else
      select($i.payloads != null) | "\($v) \($id): payloads on an image that is not the installer"
    end' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "FlockFlasher's installer entries list the payloads of the release's installer" {
  run jq -r '.channels.production as $v | .releases[$v].images as $imgs |
    .boards[].latestImages[] | select(.variant == "installer") |
    select(.payloads != $imgs[.image_id].payloads) | .image_id' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -e '[.releases[].images[] | select(.variant == "installer") | .payloads | length] | min >= 2' "$example"
  [ "$status" -eq 0 ]
}

@test "an image names its raw size and the smallest disk, both or neither, the disk at least the image" {
  run jq -r '.releases | to_entries[] | .key as $v | .value.images | to_entries[] |
    .key as $id | .value.image as $i |
    select((($i.raw_size == null) != ($i.min_disk_size == null))
      or ($i.raw_size != null and (($i.raw_size | type) != "number" or $i.raw_size < 1 or $i.min_disk_size < $i.raw_size))) |
    "\($v) \($id)"' "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The example shows them, as every release after 0.14.0 has them.
  run jq -e '[.releases[].images[].image | has("raw_size") and has("min_disk_size")] | all' "$example"
  [ "$status" -eq 0 ]
  for f in raw_size min_disk_size; do
    jq -e --arg f "$f" '."$defs".diskImage.allOf[1].properties[$f].type == "integer"' "$schema" >/dev/null
  done
  jq -e '."$defs".image.properties.image."$ref" == "#/$defs/diskImage"' "$schema" >/dev/null
}
