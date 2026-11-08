#!/usr/bin/env bats
# `just promote production [VERSION]`: what it starts, and when it starts
# nothing. curl and gh are stand-ins on PATH, so these tests read nothing from
# the download server and start no workflow.

repo="$BATS_TEST_DIRNAME/../.."

setup() {
  tmp=$(mktemp -d)
  mkdir "$tmp/bin"
  printf '#!/bin/sh\ncat "$FAKE_CATALOG"\n' >"$tmp/bin/curl"
  printf '#!/bin/sh\necho "$*" >>"$FAKE_GH_LOG"\n' >"$tmp/bin/gh"
  chmod +x "$tmp/bin/curl" "$tmp/bin/gh"
  export FAKE_CATALOG="$tmp/catalog" FAKE_GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH"
  catalog '{"channels":{"production":"0.11.0","test":"0.12.0"},"releases":{"0.10.0":{},"0.11.0":{},"0.12.0":{}}}'
}
teardown() { rm -rf "$tmp"; }

# catalog PAYLOAD: the published catalog, in its envelope.
catalog() { printf '{"payload":"%s"}' "$(printf '%s' "$1" | base64 | tr -d '\n')" >"$FAKE_CATALOG"; }

# promote ANSWER ARGS...: the recipe, with ANSWER on its standard input.
promote() {
  local answer=$1
  shift
  printf '%s\n' "$answer" | just -f "$repo/Justfile" -d "$repo" promote "$@" 2>&1
}

started() { cat "$FAKE_GH_LOG"; }
nothing_started() { [ ! -e "$FAKE_GH_LOG" ]; }

@test "without a version it takes the one on test" {
  promote y production
  [ "$(started)" = "workflow run release.yml --repo IronFlock/ironflockos --ref v0.12.0 -f promote-production=true" ]
}

@test "a named version, with or without its v" {
  promote y production 0.10.0
  promote y production v0.12.0
  [ "$(started)" = "workflow run release.yml --repo IronFlock/ironflockos --ref v0.10.0 -f promote-production=true
workflow run release.yml --repo IronFlock/ironflockos --ref v0.12.0 -f promote-production=true" ]
}

@test "anything but y starts nothing" {
  ! promote n production
  ! promote "" production
  nothing_started
}

@test "no answer at all starts nothing" {
  ! just -f "$repo/Justfile" -d "$repo" promote production </dev/null 2>&1
  nothing_started
}

@test "only production" {
  out=$(promote y test) && false
  [[ "$out" == *"only production can be promoted"* ]]
  nothing_started
}

@test "a version the catalog does not have" {
  out=$(promote y production 9.9.9) && false
  [[ "$out" == *"9.9.9 is not in the catalog"* ]]
  nothing_started
}

@test "production is on it already" {
  out=$(promote y production 0.11.0)
  [[ "$out" == *"production is already on 0.11.0"* ]]
  nothing_started
}

@test "no test channel and no version" {
  catalog '{"channels":{"production":"0.11.0"},"releases":{"0.11.0":{}}}'
  out=$(promote y production) && false
  [[ "$out" == *"the catalog has no test channel"* ]]
  nothing_started
}
