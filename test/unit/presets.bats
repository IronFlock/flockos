#!/usr/bin/env bats
# First-boot presets (systemd applies them on every slot's first boot and
# enables what none names): the units of the proxy, the trusted CAs, the network profiles and
# the apps' data are named on purpose, enabled in the image, and masked on the
# installer stick.

repo="$BATS_TEST_DIRNAME/../.."
preset="$repo/overlay/usr/lib/systemd/system-preset/10-ironflockos-device.preset"
units="$repo/overlay/usr/lib/systemd/system"
customize="$repo/build/customize.sh"

device_units="ironflockos-proxy.service ironflockos-proxy.path ironflockos-ca.service ironflockos-ca.path ironflockos-network-profiles.service
  ironflockos-network-profiles-trial.service ironflockos-apps-check.service"

@test "each of these units has its preset line, and each preset line its unit" {
  for u in $device_units; do
    grep -qx "enable $u" "$preset" || { echo "no preset for $u"; return 1; }
    grep -q '^\[Install\]' "$units/$u" || { echo "$u has no [Install]: a preset does nothing"; return 1; }
  done
  while read -r verb unit; do
    case "$verb" in '' | '#'*) continue ;; enable | disable) ;; *) echo "not a preset line: $verb $unit"; return 1 ;; esac
    [ -f "$units/$unit" ] || { echo "$unit is not a unit of the image"; return 1; }
  done <"$preset"
  # A unit without [Install] needs no line: a path unit starts it.
  for s in proxy ca; do
    ! grep -q '^\[Install\]' "$units/ironflockos-$s-reload.service"
    grep -qx "Unit=ironflockos-$s-reload.service" "$units/ironflockos-$s.path"
  done
}

@test "the image enables what the presets enable; the installer masks all of it" {
  # customize.sh with its continued lines joined.
  joined=$(awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }' "$customize")
  enabled=$(sed -n 's/^ *systemctl --root="$ROOT" enable //p' <<<"$joined" | tr -s ' ' '\n')
  masked=$(sed -n '/^if \[ "$VARIANT" = installer \]; then/,/^else/p' <<<"$joined" |
    sed -n 's/^ *systemctl --root="$ROOT" mask //p' | tr -s ' ' '\n')
  for u in $device_units; do
    # A path unit comes with its service (Also=).
    [[ "$u" == *.path ]] && continue
    grep -qx "$u" <<<"$enabled" || { echo "the image does not enable $u"; return 1; }
    grep -qx "$u" <<<"$masked" || { echo "the installer does not mask $u"; return 1; }
  done
  grep -qx ironflockos-proxy.path <<<"$masked" && grep -qx ironflockos-ca.path <<<"$masked"
  grep -qx ironflockos-ca-reload.service <<<"$masked"
}

@test "the presets sort before the distribution's, as the time preset does" {
  [[ "$(basename "$preset")" < "90-systemd.preset" ]]
}

@test "the factory reset's units need no preset: data.mount wants them, and the installer masks them" {
  for u in ironflockos-factory-reset.service ironflockos-data-missing.service; do
    ! grep -q '^\[Install\]' "$units/$u"
    [ -L "$units/data.mount.wants/$u" ] || [ -e "$units/data.mount.wants/$u" ]
    grep -q "mask .*$u" "$customize"
  done
}
