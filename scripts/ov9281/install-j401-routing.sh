#!/bin/bash
# Install the Seeed-routed OV9281 overlay. Does not edit extlinux or reboot.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
build=${1:-/tmp/ov9281-j401-routing}
name=tegra234-p3767-camera-p3768-ov9281-dual-j401
src="$build/$name.dtbo"
dst="/boot/$name.dtbo"
[[ -f "$src" ]] || { echo "Missing $src" >&2; exit 1; }
if [[ -e "$dst" ]]; then
    backup="$dst.before-$(date +%Y%m%d-%H%M%S)"
    cp -a "$dst" "$backup"
    echo "Backed up existing overlay to $backup"
fi
install -m 0644 "$src" "$dst"
echo "Installed $dst"
echo "Add OVERLAYS /boot/$name.dtbo to the active JetsonIO extlinux entry, then reboot."
