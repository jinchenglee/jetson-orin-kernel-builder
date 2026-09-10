#!/usr/bin/env bash
set -euo pipefail
depth="${1:-10}"
if [[ "$depth" != 8 && "$depth" != 10 ]]; then echo "usage: sudo $0 8|10" >&2; exit 2; fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="/tmp/ov9281-j401-720p${depth}-build"
KO="$BUILD/nv_ov9281-720p${depth}.ko"
DTBO="$BUILD/tegra234-p3767-camera-p3768-ov9281-dual-j401-720p${depth}bit.dtbo"
[[ -f "$KO" && -f "$DTBO" ]] || { echo "Build first: $ROOT/scripts/ov9281/build-j401-720p120.sh $depth" >&2; exit 1; }
KREL="$(uname -r)"
MODDIR="/lib/modules/$KREL/updates/drivers/media/i2c"
sudo install -d "$MODDIR"
if [[ -f "$MODDIR/nv_ov9281.ko" ]]; then sudo cp -a "$MODDIR/nv_ov9281.ko" "$MODDIR/nv_ov9281.ko.pre-720p${depth}"; fi
sudo install -m 0644 "$KO" "$MODDIR/nv_ov9281.ko"
sudo depmod -a "$KREL"
sudo install -m 0644 "$DTBO" "/boot/tegra234-p3767-camera-p3768-ov9281-dual-j401-720p${depth}bit.dtbo"
sudo cp -a /boot/extlinux/extlinux.conf "/boot/extlinux/extlinux.conf.pre-720p${depth}"
sudo sed -i -E "s#OVERLAYS .*/tegra234-p3767-camera-p3768-ov9281-dual-j401[^[:space:]]*#OVERLAYS /boot/tegra234-p3767-camera-p3768-ov9281-dual-j401-720p${depth}bit.dtbo#g" /boot/extlinux/extlinux.conf
echo "Installed ${depth}-bit 1280x720 OV9281 mode. Reboot, then inspect v4l2 controls and select 60 or 120 fps."
