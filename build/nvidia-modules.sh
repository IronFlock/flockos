#!/usr/bin/env bash
# NVIDIA's open kernel modules for the nvidia variant (WP-4.1; master plan,
# section 3.7). Runs inside the image tree as mmdebstrap's chrooted
# customize hook (build/mkrootfs.sh), with the image's apt sources:
#   nvidia-modules.sh DRIVER_VERSION        e.g. 620.70.06-1
#
# 1. Installs the headers of the image's kernel and nvidia-kernel-open-dkms
#    at DRIVER_VERSION; DKMS builds the modules for that kernel (not for the
#    build host's).
# 2. Wraps the built modules in a package, flockos-nvidia-modules, so dpkg
#    owns them and packages.tsv lists them.
# 3. Purges everything step 1 installed: DKMS, the module sources, the
#    headers, the compiler. The image ends with the package set it started
#    with plus flockos-nvidia-modules, or the build fails.
set -euo pipefail
[ "$#" -eq 1 ] || {
  echo "usage: nvidia-modules.sh DRIVER_VERSION" >&2
  exit 2
}
driver=$1
modver=${driver%-*}
log() { printf '==> nvidia-modules: %s\n' "$*" >&2; }
die() {
  printf 'error: nvidia-modules: %s\n' "$*" >&2
  exit 1
}
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

mapfile -t kernels < <(ls /lib/modules)
[ "${#kernels[@]}" -eq 1 ] || die "expected one kernel in /lib/modules, found: ${kernels[*]}"
kver=${kernels[0]}

installed() { dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" { print $2 }' | sort; }
before=$(installed)

log "building $modver for $kver"
apt-get install -y -q --no-install-recommends "linux-headers-$kver" "nvidia-kernel-open-dkms=$driver"
# The headers' or the package's postinst usually built it already.
if ! dkms status -m nvidia -v "$modver" -k "$kver" | grep -q ': installed'; then
  dkms install -m nvidia -v "$modver" -k "$kver"
fi

built=/lib/modules/$kver/updates/dkms
pkg=/tmp/flockos-nvidia-modules
rm -rf "$pkg"
mkdir -p "$pkg/DEBIAN" "$pkg/usr/lib/modules/$kver/updates/nvidia"
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
  f=$(find "$built" -maxdepth 1 -name "$m.ko*" -print -quit)
  [ -n "$f" ] || die "DKMS built no $m module in $built"
  cp "$f" "$pkg/usr/lib/modules/$kver/updates/nvidia/"
done
got=$(modinfo -F version "$pkg/usr/lib/modules/$kver/updates/nvidia/"nvidia.ko*)
[ "$got" = "$modver" ] || die "the built nvidia module is version $got, not $modver"
vermagic=$(modinfo -F vermagic "$pkg/usr/lib/modules/$kver/updates/nvidia/"nvidia.ko*)
[ "${vermagic%% *}" = "$kver" ] || die "the built nvidia module is for ${vermagic%% *}, not $kver"
# The licence of the modules is their source's: nvidia-kernel-open-dkms's
# copyright file (MIT; a kernel module linked from it is MIT/GPL-2.0). The
# release publishes the source (release/sources).
doc=$pkg/usr/share/doc/flockos-nvidia-modules
mkdir -p "$doc"
[ -f /usr/share/doc/nvidia-kernel-open-dkms/copyright ] || die "nvidia-kernel-open-dkms $driver has no copyright file"
cp /usr/share/doc/nvidia-kernel-open-dkms/copyright "$doc/copyright"

cat >"$pkg/DEBIAN/control" <<CONTROL
Package: flockos-nvidia-modules
Version: $driver
Architecture: $(dpkg --print-architecture)
Maintainer: IronFlock <security@ironflock.com>
Depends: firmware-nvidia-gsp (= $driver), nvidia-kernel-support (= $driver)
Provides: nvidia-kernel-$modver
Section: non-free/kernel
Priority: optional
Description: NVIDIA open GPU kernel modules $modver for Linux $kver
 Built by the FlockOS image build from nvidia-kernel-open-dkms $driver,
 which it purges afterwards with DKMS, the kernel headers and the compiler.
CONTROL
cat >"$pkg/DEBIAN/postinst" <<POSTINST
#!/bin/sh
set -e
depmod -a $kver
POSTINST
chmod 0755 "$pkg/DEBIAN/postinst"
dpkg-deb --root-owner-group --build "$pkg" /tmp/flockos-nvidia-modules.deb >/dev/null
dpkg -i /tmp/flockos-nvidia-modules.deb
rm -rf "$pkg" /tmp/flockos-nvidia-modules.deb

# Everything the build installed goes again.
mapfile -t added < <(comm -13 <(echo "$before") <(installed) | grep -vx flockos-nvidia-modules)
log "purging the build tools: ${added[*]}"
apt-get purge -y -q "${added[@]}"
rm -rf /var/lib/dkms /etc/dkms /usr/src/nvidia-*
expected=$(printf '%s\nflockos-nvidia-modules\n' "$before" | sort)
if [ "$(installed)" != "$expected" ]; then
  die "the package set changed beyond flockos-nvidia-modules: $(diff <(echo "$expected") <(installed) | grep '^[<>]' | tr '\n' ' ')"
fi
for tool in cc gcc g++ make dkms; do
  ! command -v "$tool" >/dev/null || die "$tool is still in the image"
done

depmod -a "$kver"
# The initramfs applies nvidia-kernel-support's blacklist of nouveau and
# nova-core.
update-initramfs -u -k "$kver"
log "flockos-nvidia-modules $driver for $kver installed"
