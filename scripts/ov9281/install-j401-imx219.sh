#!/bin/bash
# Install the staged J401 IMX219 overlay. Does not edit extlinux or reboot.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
build=${1:-/tmp/j401-imx219-build}
name=tegra234-p3767-camera-p3768-imx219-dual-j401
src="$build/$name.dtbo"
dst="/boot/$name.dtbo"
[[ -f "$src" ]]
if [[ -e "$dst" ]]; then
  backup="$dst.before-$(date +%Y%m%d-%H%M%S)"
  cp -a "$dst" "$backup"
  echo "Backed up existing overlay to $backup"
fi
install -m 0644 "$src" "$dst"
echo "Installed $dst"
echo "Select it with jetson-io.py if it appears as Camera IMX219 Dual J401."
echo "Otherwise add OVERLAYS /boot/$name.dtbo to the active extlinux entry, then reboot."
