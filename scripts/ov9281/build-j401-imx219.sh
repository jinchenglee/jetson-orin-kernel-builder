#!/bin/bash
# Build a J401 IMX219 overlay from NVIDIA's stock dual-IMX219 sources.
# Match Seeed's J401 overlay: CAM0 uses serial_a and CSI/VI port 0.
# Sensor mode data and CAM1 routing remain stock.
set -euo pipefail

bsp=${1:-/home/nvidia/l4t/r36.4.7}
out=${2:-/tmp/j401-imx219-build}
name=tegra234-p3767-camera-p3768-imx219-dual-j401
stock_dts="$bsp/hardware/nvidia/t23x/nv-public/overlay/tegra234-p3767-camera-p3768-imx219-dual.dts"
stock_dtsi="$bsp/hardware/nvidia/t23x/nv-public/overlay/tegra234-camera-rbpcv2-imx219.dtsi"
include_dir="$bsp/hardware/nvidia/t23x/nv-public/include"
platform_dir="$bsp/hardware/nvidia/t23x/nv-public/include/platforms"
kernel_include="$bsp/kernel/kernel-jammy-src/include"

rm -rf "$out"
mkdir -p "$out"
cp "$stock_dts" "$out/$name.dts"
cp "$stock_dtsi" "$out/tegra234-camera-rbpcv2-imx219-j401.dtsi"

# The stock dtsi has five CAM0 modes followed by five CAM1 modes. Replace only
# CAM0's repeated carrier routing fields. Keep all IMX219 timing/mode values.
sed -i '0,/tegra234-camera-rbpcv2-imx219.dtsi/s//tegra234-camera-rbpcv2-imx219-j401.dtsi/' "$out/$name.dts"
perl -pi -e 'if (/tegra_sinterface = "serial_b"/ && ++$n <= 5) { s/serial_b/serial_a/; } if (/port-index = <1>/ && ++$p <= 3) { s/port-index = <1>/port-index = <0>/; }' "$out/tegra234-camera-rbpcv2-imx219-j401.dtsi"
sed -i "s/overlay-name = \"Camera IMX219 Dual\"/overlay-name = \"Camera IMX219 Dual J401\"/" "$out/$name.dts"

gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
  -I "$platform_dir" -I "$include_dir" -I "$kernel_include" \
  "$out/$name.dts" -o "$out/$name.preprocessed.dts"
dtc -@ -I dts -O dtb -o "$out/$name.dtbo" "$out/$name.preprocessed.dts"

echo "Built $out/$name.dtbo"
echo "CAM0 routing (Seeed J401): serial_a, port-index 0, lane_polarity 6"
echo "CAM0 port-index values:" "$(rg 'port-index' "$out/tegra234-camera-rbpcv2-imx219-j401.dtsi" | head -3 | tr '\n' ' ')"
echo "CAM1 routing remains stock serial_c / port-index 2."
