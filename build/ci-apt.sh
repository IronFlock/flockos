#!/usr/bin/env bash
# Installs packages on a CI runner with apt-get, and asks public resolvers for
# the archive's names when the runner's resolver does not know them.
#
#   ci-apt.sh <package>...
#
# On 2026-11-11 the hosted runners could not resolve the names of Ubuntu's
# archive for hours, while the archive was up and public resolvers answered.
# apt-get waited out every name: a test job hung for 14 to 50 minutes and then
# failed. So this script
#
#   1. asks for the names in the runner's package sources first, and switches
#      to public resolvers at once when one of them does not resolve;
#   2. gives one apt-get try 10 minutes;
#   3. tries a second time when the first try fails, through public resolvers
#      when the first try did not use them yet.
#
# What is installed is the same either way.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$here/lib.sh"

[ $# -gt 0 ] || die "usage: ci-apt.sh <package>..."

# The tests set these (test/unit/ci-apt.bats).
resolv=${CI_APT_RESOLV_CONF:-/etc/resolv.conf}
sources=${CI_APT_SOURCES:-/etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/apt-mirrors.txt}
sudo=${CI_APT_SUDO-sudo}
limit=${CI_APT_TIMEOUT:-600}

# hosts: the host names in the runner's package sources, one per line.
hosts() {
  # shellcheck disable=SC2086 # a space-separated list of files and folders
  grep -rhoE 'https?://[A-Za-z0-9.-]+' $sources 2>/dev/null | sed 's|^[a-z]*://||' | sort -u || true
}

# resolves: does every host of the package sources resolve?
resolves() {
  local h bad=0
  for h in $(hosts); do
    timeout 15 getent hosts "$h" >/dev/null || {
      warn "$h does not resolve"
      bad=1
    }
  done
  return "$bad"
}

public=0
public_resolvers() {
  echo "::warning::ci-apt: $1; asking public resolvers (1.1.1.1, 8.8.8.8)"
  # resolv.conf is a link into systemd-resolved's folder on the runners.
  $sudo rm -f "$resolv"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | $sudo tee "$resolv" >/dev/null
  public=1
}

fetch() {
  $sudo timeout "$limit" apt-get update -qq &&
    $sudo timeout "$limit" apt-get install -y -qq --no-install-recommends "$@"
}

resolves || public_resolvers "a name of the package sources does not resolve"
if ! fetch "$@"; then
  if [ "$public" = 0 ]; then
    public_resolvers "apt-get failed"
  else
    echo "::warning::ci-apt: apt-get failed; second try"
  fi
  fetch "$@" || die "apt-get failed twice: $*"
fi
log "installed: $*"
