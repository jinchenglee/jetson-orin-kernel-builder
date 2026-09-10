#!/bin/bash
# Build only the experimental sensor module and overlay in an isolated directory.
set -euo pipefail
bsp=${1:-/home/nvidia/l4t/r36.4.7}
out=${2:-/tmp/ov9281-controls-build}
carrier=${3:-reference}
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
kernel=$(uname -r)
mkdir -p "$out/nvidia-oot/drivers/media/i2c" "$out/hardware/nvidia/t23x/nv-public/overlay"
cp "$bsp/nvidia-oot/drivers/media/i2c/nv_ov9281.c" "$bsp/nvidia-oot/drivers/media/i2c/ov9281_mode_tbls.h" "$out/nvidia-oot/drivers/media/i2c/"
overlay=tegra234-p3767-camera-p3768-ov9281-dual
cp "$bsp/hardware/nvidia/t23x/nv-public/overlay/$overlay.dts" "$out/hardware/nvidia/t23x/nv-public/overlay/"
patch --batch -d "$out" -p1 < "$script_dir/controls.patch"
if [[ "$carrier" == "j401" ]]; then
    # Seeed J401 CAM0 routing: serial_a, CSI/VI port 0, polarity 6.
    # The stock OV9281 overlay has three CAM0 port-index=<1> sites and five
    # CAM0 serial_b mode properties; CAM1 remains serial_c/port 2/polarity 0.
    perl -pi -e 'if (/tegra_sinterface = "serial_b"/ && ++$n <= 5) { s/serial_b/serial_a/; } if (/port-index = <1>/ && ++$p <= 3) { s/port-index = <1>/port-index = <0>/; }' \
        "$out/hardware/nvidia/t23x/nv-public/overlay/$overlay.dts"
elif [[ "$carrier" != "reference" ]]; then
    echo "Unknown carrier '$carrier' (use reference or j401)." >&2
    exit 2
fi
mkdir -p "$out/nvidia-oot/drivers/media/platform/tegra/camera"
cp "$bsp/nvidia-oot/drivers/media/platform/tegra/camera/camera_gpio.h" "$out/nvidia-oot/drivers/media/platform/tegra/camera/"
cat > "$out/nvidia-oot/drivers/media/i2c/Makefile" <<EOF
obj-m += nv_ov9281.o
ccflags-y += -I$bsp/nvidia-oot/include -I$bsp/out/nvidia-conftest -Werror
EOF
make -C "/lib/modules/$kernel/build" M="$out/nvidia-oot/drivers/media/i2c" \
    KBUILD_EXTRA_SYMBOLS="$bsp/nvidia-oot/Module.symvers" modules
cp "$out/nvidia-oot/drivers/media/i2c/nv_ov9281.ko" "$out/nv_ov9281.ko"
gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$bsp/hardware/nvidia/t23x/nv-public/include/platforms" \
    -I "$bsp/hardware/nvidia/t23x/nv-public/include" \
    -I "$bsp/kernel/kernel-jammy-src/include" \
    "$out/hardware/nvidia/t23x/nv-public/overlay/$overlay.dts" -o "$out/overlay.preprocessed.dts"
dtc -@ -I dts -O dtb -o "$out/$overlay.dtbo" "$out/overlay.preprocessed.dts"
modinfo -F vermagic "$out/nv_ov9281.ko"
echo "Built experimental module and overlay in $out"
