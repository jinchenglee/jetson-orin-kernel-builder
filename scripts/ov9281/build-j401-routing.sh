#!/bin/bash
# Rebuild the active, patched OV9281 overlay with Seeed J401 CAM0 routing.
# Sensor mode/control properties are copied from the active overlay unchanged.
set -euo pipefail

src=${1:-/boot/tegra234-p3767-camera-p3768-ov9281-dual.dtbo}
out=${2:-/tmp/ov9281-j401-routing}
name=tegra234-p3767-camera-p3768-ov9281-dual-j401

[[ -f "$src" ]] || { echo "Missing source overlay: $src" >&2; exit 1; }
command -v dtc >/dev/null || { echo 'dtc is required.' >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out"
dtc -I dtb -O dts -o "$out/$name.dts" "$src"

# Seeed J401: CAM0 is serial_a on CSI0. There are three CAM0 port-index sites:
# VI endpoint, NVCSI input endpoint, and sensor output endpoint. Preserve the
# active OV9281 sensor settings and lane polarity 6.
perl -pi -e 'if (/port-index = <0x01>/ && ++$p <= 3) { s/port-index = <0x01>/port-index = <0x00>/; }' "$out/$name.dts"

dtc -@ -I dts -O dtb -o "$out/$name.dtbo" "$out/$name.dts"
dtc -I dtb -O dts -o "$out/check.dts" "$out/$name.dtbo" 2>/dev/null
grep -q 'tegra_sinterface = "serial_a"' "$out/check.dts"
test "$(grep -c 'port-index = <0x00>' "$out/check.dts")" -ge 3
grep -q 'csi_pixel_bit_depth = "10"' "$out/check.dts"
echo "Built $out/$name.dtbo"
echo 'CAM0: serial_a, port-index 0, lane_polarity 6'
echo 'CAM1: serial_c, port-index 2, unchanged sensor settings'
