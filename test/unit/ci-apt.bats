#!/usr/bin/env bats
# build/ci-apt.sh: apt-get on a CI runner, with public resolvers when the
# runner's resolver does not know the archive's names or apt-get fails. The
# tests run it against stand-ins for apt-get, getent and timeout; the two
# workflow steps that install packages on a runner must use it, and no step
# of this repository's workflows may run apt or apt-get itself.

repo="$BATS_TEST_DIRNAME/../.."
script="$repo/build/ci-apt.sh"

setup() {
  t=$(mktemp -d)
  mkdir "$t/bin" "$t/sources"
  echo "nameserver 127.0.0.53" >"$t/resolv.conf"
  printf 'deb http://azure.archive.ubuntu.com/ubuntu/ noble main\ndeb https://security.ubuntu.com/ubuntu noble-security main\n' >"$t/sources/ubuntu.list"
  # timeout: runs the command, without the limit.
  printf '#!/bin/bash\nshift\nexec "$@"\n' >"$t/bin/timeout"
  # getent: every name resolves unless it is listed in $t/unknown.
  cat >"$t/bin/getent" <<EOF
#!/bin/bash
! grep -qxF "\$2" "$t/unknown" 2>/dev/null
EOF
  # apt-get: logs its call and the resolver file of that moment; fails as
  # often as $t/fail says.
  cat >"$t/bin/apt-get" <<EOF
#!/bin/bash
echo "\$* [\$(tr '\n' ' ' <"$t/resolv.conf")]" >>"$t/calls"
n=\$(cat "$t/fail" 2>/dev/null || echo 0)
if [ "\$n" -gt 0 ]; then echo \$((n - 1)) >"$t/fail"; exit 100; fi
EOF
  chmod +x "$t/bin/"*
}

teardown() { rm -rf "$t"; }

apt() {
  run env PATH="$t/bin:$PATH" CI_APT_SUDO="" CI_APT_RESOLV_CONF="$t/resolv.conf" CI_APT_SOURCES="$t/sources $t/missing" bash "$script" "$@"
}

@test "names resolve and apt-get works: the runner's resolver stays" {
  apt qemu-utils mtools
  [ "$status" -eq 0 ]
  [ "$(cat "$t/resolv.conf")" = "nameserver 127.0.0.53" ]
  [ "$(wc -l <"$t/calls")" -eq 2 ]
  [ "$(sed -n 1p "$t/calls")" = "update -qq [nameserver 127.0.0.53 ]" ]
  [ "$(sed -n 2p "$t/calls")" = "install -y -qq --no-install-recommends qemu-utils mtools [nameserver 127.0.0.53 ]" ]
}

@test "a name of the sources does not resolve: public resolvers before the first try" {
  echo azure.archive.ubuntu.com >"$t/unknown"
  apt mtools
  [ "$status" -eq 0 ]
  [[ "$output" == *"azure.archive.ubuntu.com does not resolve"* ]]
  [[ "$output" == *"::warning::ci-apt: a name of the package sources does not resolve"* ]]
  [ "$(wc -l <"$t/calls")" -eq 2 ]
  [ "$(sed -n 1p "$t/calls")" = "update -qq [nameserver 1.1.1.1 nameserver 8.8.8.8 ]" ]
}

@test "apt-get fails once: the second try asks public resolvers" {
  echo 1 >"$t/fail"
  apt mtools
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::ci-apt: apt-get failed; asking public resolvers"* ]]
  [ "$(wc -l <"$t/calls")" -eq 3 ]
  [ "$(sed -n 1p "$t/calls")" = "update -qq [nameserver 127.0.0.53 ]" ]
  [ "$(sed -n 3p "$t/calls")" = "install -y -qq --no-install-recommends mtools [nameserver 1.1.1.1 nameserver 8.8.8.8 ]" ]
}

@test "the install fails once after a good update: both run again" {
  # update succeeds, install fails, then update and install succeed
  cat >"$t/bin/apt-get" <<EOF
#!/bin/bash
echo "\$1" >>"$t/calls"
[ "\$1" != install ] || [ -e "$t/second" ] || { touch "$t/second"; exit 100; }
EOF
  apt mtools
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' <"$t/calls")" = "update install update install " ]
}

@test "apt-get fails twice: the step fails" {
  echo 5 >"$t/fail"
  apt mtools
  [ "$status" -ne 0 ]
  [[ "$output" == *"apt-get failed twice: mtools"* ]]
  [ "$(wc -l <"$t/calls")" -eq 2 ]
}

@test "public resolvers already asked and apt-get fails once: one more try, no second switch" {
  echo security.ubuntu.com >"$t/unknown"
  echo 1 >"$t/fail"
  apt mtools
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::ci-apt: apt-get failed; second try"* ]]
  [ "$(grep -c 'asking public resolvers' <<<"$output")" -eq 1 ]
}

@test "no package is a usage error, and nothing is installed" {
  apt
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: ci-apt.sh"* ]]
  [ ! -e "$t/calls" ]
}

# apt_calls FILE...: the lines of FILE... that run apt or apt-get update or
# install, with any options between the command and the verb; a line that
# ends in a backslash is joined with the next.
apt_calls() {
  awk '{ if (sub(/\\$/, "")) { buf = buf $0 " "; next } print FILENAME ":" FNR ": " buf $0; buf = "" }' "$@" |
    grep -E '(^|[^[:alnum:]_.-])apt(-get)?[[:space:]]+([^|;&]*[[:space:]])?(update|install)([[:space:]]|$)'
}

@test "the workflows install packages on a runner only through ci-apt.sh" {
  # The pattern: the calls it must find, and the lines it must leave alone.
  for call in 'apt-get install -y mtools' 'apt-get -y install mtools' 'apt-get -qq update' 'sudo apt install x' \
    'sudo apt-get -o Acquire::Retries=5 install x' 'sudo apt-get --yes --no-install-recommends install x' \
    'DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update' $'sudo apt-get -y \\\n  install x'; do
    printf '%s\n' "$call" >"$t/call"
    apt_calls "$t/call" >/dev/null || { echo "missed: $call"; return 1; }
  done
  for line in 'build/ci-apt.sh qemu-utils mtools' 'apt-cache policy rauc' 'apt-mark hold rauc' \
    'rauc install x.raucb' '# apt in the build container finds the sources' '--no-install-recommends'; do
    printf '%s\n' "$line" >"$t/call"
    ! apt_calls "$t/call" >/dev/null || { echo "matched: $line"; return 1; }
  done
  # No step of this repository's workflows runs apt or apt-get itself. The
  # test cannot see the steps of reusable workflows from other repositories:
  # the shared harness, IronFlock/workflows, has its own fallback for that
  # since v1.7.3 (scripts/apt-install.sh).
  run apt_calls "$repo"/.github/workflows/*.yml
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  grep -q 'build/ci-apt.sh \$QEMU_PACKAGES qemu-utils mtools' "$repo/.github/workflows/qemu-test.yml"
  grep -q 'build/ci-apt.sh qemu-system-x86 qemu-utils ovmf mtools' "$repo/.github/workflows/release.yml"
}
