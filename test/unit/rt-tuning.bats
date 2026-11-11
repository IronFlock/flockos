#!/usr/bin/env bats
# rt-tuning (WP-4b.1): rt.conf to kernel parameters in grubenv, applied at the
# next boot; THP and the governor at once.

tuning="$BATS_TEST_DIRNAME/../../profiles/kernel-rt/overlay/usr/lib/ironflockos/rt-tuning"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin" "$tmp/sys/kernel/mm/transparent_hugepage" "$tmp/sys/devices/system/cpu/cpu0/cpufreq"
  echo "always [madvise] never" >"$tmp/sys/kernel/mm/transparent_hugepage/enabled"
  echo schedutil >"$tmp/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  # grub-editenv FILE list | set KEY=VALUE, on a plain KEY=VALUE file.
  cat >"$tmp/bin/grub-editenv" <<'SH'
#!/bin/bash
f=$1
case "$2" in
  list) cat "$f" 2>/dev/null ;;
  set) key=${3%%=*}; { grep -v "^$key=" "$f" 2>/dev/null; echo "$3"; } >"$f.new"; mv "$f.new" "$f" ;;
esac
SH
  chmod +x "$tmp/bin/grub-editenv"
  export PATH="$tmp/bin:$PATH" IRONFLOCKOS_RT_CONF=$tmp/rt.conf IRONFLOCKOS_GRUBENV=$tmp/grubenv \
    IRONFLOCKOS_SYS=$tmp/sys IRONFLOCKOS_RUN=$tmp/run IRONFLOCKOS_ARCH=amd64
}

teardown() { rm -rf "$tmp"; }

@test "without rt.conf: C-states limited, no isolation; THP never, governor performance" {
  run bash "$tuning"
  [ "$status" -eq 0 ]
  grep -qx 'IRONFLOCKOS_RT_CMDLINE=nosoftlockup processor.max_cstate=1 intel_idle.max_cstate=0' "$tmp/grubenv"
  [ "$(cat "$tmp/sys/kernel/mm/transparent_hugepage/enabled")" = never ]
  [ "$(cat "$tmp/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")" = performance ]
  [ -e "$tmp/run/rt-reboot-required" ]
}

@test "isolated CPUs and interrupt CPUs become kernel parameters" {
  printf 'isolate=2-3\nirq=0-1\n' >"$tmp/rt.conf"
  run bash "$tuning"
  [ "$status" -eq 0 ]
  grep -q 'isolcpus=managed_irq,domain,2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1' "$tmp/grubenv"
}

@test "an unchanged configuration needs no reboot" {
  printf 'isolate=3\n' >"$tmp/rt.conf"
  bash "$tuning"
  run bash "$tuning"
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/run/rt-reboot-required" ]
  [[ "$output" != *"apply at the next boot"* ]]
}

@test "cstates=on and arm64 leave the C-state parameters out" {
  printf 'cstates=on\n' >"$tmp/rt.conf"
  bash "$tuning"
  grep -qx 'IRONFLOCKOS_RT_CMDLINE=nosoftlockup' "$tmp/grubenv"
  printf 'cstates=limit\n' >"$tmp/rt.conf"
  IRONFLOCKOS_ARCH=arm64 bash "$tuning"
  grep -qx 'IRONFLOCKOS_RT_CMDLINE=nosoftlockup processor.max_cstate=1' "$tmp/grubenv"
}

@test "refuses what is not a CPU list or a known key, and changes nothing" {
  for bad in 'isolate=2-3 nosmt' 'isolate=$(reboot)' 'isolate=a-b' 'cstates=off' 'thp=sometimes' 'colour=blue'; do
    printf '%s\n' "$bad" >"$tmp/rt.conf"
    run bash "$tuning"
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [ ! -e "$tmp/grubenv" ]
  done
}
