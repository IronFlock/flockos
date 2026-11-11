#!/usr/bin/env bash
# The last job of release.yml (release-ok): did every job that this run's mode
# needs succeed, and was every other job skipped? A job skipped by mistake
# (a condition that went wrong) fails the run, the dry run too.
#
#   NEEDS='<toJSON(needs)>' EVENT=<event> PROMOTE=<true|false|> release-check.sh
#
# The mode comes from verify's output, whether the run reused its images from
# source's. The table:
#
#   verify skipped     a push that releases nothing: every job skipped
#   release, dry-run   source: succeeded
#                      build, manifest: skipped when it reused, else succeeded
#                      attest-build, would-reuse: succeeded in a dry run of a
#                        pull request that built, else skipped
#                      sign, attest, e2e, stage, sources, promote, vm-images:
#                        succeeded
#                      tag, assets: succeeded in a release, skipped in a dry run
#                      production: skipped
#   tag                production: succeeded when PROMOTE is true, else
#                      skipped; every other job skipped
#   released           every job skipped (a re-run after the tag)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

# Every job of release.yml but release-ok (test/unit/release-check.bats).
JOBS="verify source build manifest attest-build would-reuse sign attest e2e stage sources promote vm-images production tag assets"

: "${NEEDS:?NEEDS is toJSON(needs) of release-ok}"
require jq
event=${EVENT:-}
promote=${PROMOTE:-}

result() { jq -r --arg j "$1" '.[$j].result // "missing"' <<<"$NEEDS"; }
mode=$(jq -r '.verify.outputs.mode // ""' <<<"$NEEDS")
reuse=$(jq -r '.source.outputs.reuse // ""' <<<"$NEEDS")

# want JOB: the results the job may have in this run, space-separated.
want() {
  local reused=false
  if [ "$(result verify)" = skipped ]; then
    echo skipped
    return
  fi
  [ "$1" = verify ] && {
    echo success
    return
  }
  case "$mode" in
    release | dry-run)
      if [ "$(result source)" = success ] && [ "$reuse" = true ]; then reused=true; fi
      case "$1" in
        source) echo success ;;
        build | manifest) if [ "$reused" = true ]; then echo skipped; else echo success; fi ;;
        attest-build | would-reuse)
          if [ "$mode" = dry-run ] && [ "$event" = pull_request ] && [ "$reused" = false ]; then echo success; else echo skipped; fi
          ;;
        sign | attest | e2e | stage | sources | promote | vm-images) echo success ;;
        tag | assets) if [ "$mode" = release ]; then echo success; else echo skipped; fi ;;
        production) echo skipped ;;
        *) echo unknown ;;
      esac
      ;;
    tag)
      case "$1" in
        production) if [ "$promote" = true ]; then echo success; else echo skipped; fi ;;
        *) echo skipped ;;
      esac
      ;;
    released) echo skipped ;;
    *) echo "a mode" ;;
  esac
}

bad=0
for job in $JOBS; do
  got=$(result "$job")
  ok=$(want "$job")
  if [[ " $ok " == *" $got "* ]]; then
    printf '  ok   %-12s %s\n' "$job" "$got"
  else
    printf '  FAIL %-12s %s, expected %s\n' "$job" "$got" "${ok// / or }"
    bad=1
  fi
done
# a job the table does not know
extra=$(jq -r --arg jobs " $JOBS " 'keys[] as $k | select(($jobs | contains(" " + $k + " ")) | not) | $k' <<<"$NEEDS")
[ -z "$extra" ] || {
  echo "  FAIL jobs the table does not know: $extra"
  bad=1
}
if [ "$bad" = 0 ]; then
  log "mode ${mode:-none}${reuse:+, reuse $reuse}: every job ran or was skipped as it must"
else
  die "mode ${mode:-none}${reuse:+, reuse $reuse}: a job failed, or ran or was skipped against its mode (above)"
fi
