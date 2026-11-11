#!/usr/bin/env bats
# release.yml's job graph: every job after a job that a mode can skip names
# its needs' results (a skipped ancestor would skip it silently otherwise),
# and release-ok (build/release-check.sh) fails a run in which a job ran or
# was skipped against the run's mode.

repo="$BATS_TEST_DIRNAME/../.."
check="$repo/build/release-check.sh"
wf="$repo/.github/workflows/release.yml"

# jobs: the jobs of release.yml.
jobs() { awk '/^jobs:/ { f = 1; next } f && /^  [a-z][a-z0-9-]*:$/ { sub(/:$/, "", $1); print $1 }' "$wf"; }
# needs JOB: a job's direct needs, one per line.
needs() {
  awk -v job="  $1:" '$0 == job { f = 1; next } f && /^  [a-z]/ { exit } f && /^    needs: \[/ { print; exit }' "$wf" |
    sed 's/.*\[//; s/\].*//; s/, */\n/g'
}
# cond JOB: a job's if.
cond() { awk -v job="  $1:" '$0 == job { f = 1; next } f && /^  [a-z]/ { exit } f && /^    if: / { print; exit }' "$wf"; }

# results MODE REUSE [JOB=RESULT...]: NEEDS of a run in which every job had
# the result the table wants for MODE (release, dry-run, dry-run-dispatch,
# tag, released), changed by JOB=RESULT.
results() {
  local mode=$1 reuse=$2 j r
  shift 2
  declare -A res=()
  for j in verify source build manifest attest-build would-reuse sign attest e2e stage sources promote vm-images production tag assets; do res[$j]=skipped; done
  case "$mode" in
    release | dry-run | dry-run-dispatch)
      for j in verify source sign attest e2e stage sources promote vm-images; do res[$j]=success; done
      if [ "$reuse" != true ]; then res[build]=success res[manifest]=success; fi
      if [ "$mode" = release ]; then res[tag]=success res[assets]=success; fi
      if [ "$mode" = dry-run ] && [ "$reuse" != true ]; then res[attest-build]=success res[would-reuse]=success; fi
      ;;
    tag | released) res[verify]=success ;;
  esac
  for a in "$@"; do res[${a%%=*}]=${a#*=}; done
  local m=${mode%-dispatch}
  for j in "${!res[@]}"; do
    case "$j" in
      verify) jq -n --arg r "${res[$j]}" --arg m "$m" '{verify: {result: $r, outputs: {mode: $m}}}' ;;
      source) jq -n --arg r "${res[$j]}" --arg u "$reuse" '{source: {result: $r, outputs: {reuse: $u}}}' ;;
      *) jq -n --arg j "$j" --arg r "${res[$j]}" '{($j): {result: $r, outputs: {}}}' ;;
    esac
  done | jq -s 'add'
}

# run_check MODE REUSE [JOB=RESULT...]
run_check() {
  local mode=$1 event=pull_request
  [ "$mode" != dry-run-dispatch ] || event=workflow_dispatch
  [ "$mode" != release ] || event=push
  run env NEEDS="$(results "$@")" EVENT="$event" PROMOTE="${PROMOTE:-}" bash "$check"
}

@test "release-ok knows every job of release.yml, needs each, and always runs" {
  table=$(sed -n 's/^JOBS="\(.*\)"$/\1/p' "$check" | tr ' ' '\n' | sort)
  [ "$table" = "$(jobs | grep -vx release-ok | sort)" ]
  [ "$(needs release-ok | sort)" = "$table" ]
  [ "$(cond release-ok)" = "    if: always()" ]
}

@test "every job with needs names each need's result and checks for a cancelled run" {
  for job in $(jobs | grep -vx release-ok); do
    n=$(needs "$job")
    [ -n "$n" ] || continue
    c=$(cond "$job")
    [[ "$c" == "    if: \${{ !cancelled() && "* ]] || { echo "$job: $c"; return 1; }
    for need in $n; do
      [[ "$c" == *"needs.$need.result "* ]] || { echo "$job does not name needs.$need.result: $c"; return 1; }
    done
  done
}

@test "every mode gate is kept" {
  for job in source build manifest sign attest e2e stage sources promote vm-images; do
    [[ "$(cond "$job")" == *"(needs.verify.outputs.mode == 'release' || needs.verify.outputs.mode == 'dry-run')"* ]] || { echo "$job"; return 1; }
  done
  for job in tag assets; do [[ "$(cond "$job")" == *"needs.verify.outputs.mode == 'release'"* ]]; done
  [[ "$(cond production)" == *"needs.verify.outputs.mode == 'tag' && inputs.promote-production"* ]]
  for job in attest-build would-reuse; do
    [[ "$(cond "$job")" == *"needs.verify.outputs.mode == 'dry-run' && github.event_name == 'pull_request'"* ]]
  done
}

@test "a release that reuses: every job after sign must succeed" {
  run_check release true
  [ "$status" -eq 0 ]
  # the blocker: sign succeeded, everything after it skipped
  run_check release true attest=skipped e2e=skipped stage=skipped sources=skipped promote=skipped vm-images=skipped tag=skipped assets=skipped
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL attest       skipped, expected success"* ]]
  run_check release true tag=skipped
  [ "$status" -ne 0 ]
  # a build in a release that reused
  run_check release true build=success
  [ "$status" -ne 0 ]
}

@test "a release that builds: build and manifest succeed" {
  run_check release false
  [ "$status" -eq 0 ]
  run_check release false source=failure
  [ "$status" -ne 0 ]
  run_check release false build=skipped manifest=skipped
  [ "$status" -ne 0 ]
  run_check release false source=skipped
  [ "$status" -ne 0 ]
  run_check release false would-reuse=success
  [ "$status" -ne 0 ]
}

@test "a dry run: the reuse check on a pull request, not on a manual run; no tag" {
  run_check dry-run false
  [ "$status" -eq 0 ]
  run_check dry-run false would-reuse=skipped
  [ "$status" -ne 0 ]
  run_check dry-run false would-reuse=failure
  [ "$status" -ne 0 ]
  run_check dry-run false tag=success
  [ "$status" -ne 0 ]
  run_check dry-run-dispatch false
  [ "$status" -eq 0 ]
  run_check dry-run-dispatch false attest-build=success
  [ "$status" -ne 0 ]
  # a dry run that reuses an earlier run's images (the trial)
  run_check dry-run-dispatch true
  [ "$status" -eq 0 ]
}

@test "the other modes: production promotion, a re-run after the tag, a push that releases nothing" {
  PROMOTE=true run_check tag false production=success
  [ "$status" -eq 0 ]
  PROMOTE=true run_check tag false production=skipped
  [ "$status" -ne 0 ]
  PROMOTE=false run_check tag false
  [ "$status" -eq 0 ]
  run_check tag false build=success
  [ "$status" -ne 0 ]
  run_check released false
  [ "$status" -eq 0 ]
  run_check released false sign=success
  [ "$status" -ne 0 ]
  run_check none false verify=skipped
  [ "$status" -eq 0 ]
  run_check none false verify=failure
  [ "$status" -ne 0 ]
}

@test "a job the table does not know, or one it misses, fails it" {
  run env NEEDS="$(results release true | jq '. + {new: {result: "success"}}')" EVENT=push bash "$check"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jobs the table does not know: new"* ]]
  run env NEEDS="$(results release true | jq 'del(.e2e)')" EVENT=push bash "$check"
  [ "$status" -ne 0 ]
}
