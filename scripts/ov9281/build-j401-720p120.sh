#!/usr/bin/env bash
set -euo pipefail
depth="${1:-10}"
if [[ "$depth" != 8 && "$depth" != 10 ]]; then echo "usage: $0 8|10" >&2; exit 2; fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
L4T=/home/nvidia/l4t/r36.4.7
SRC="$L4T/nvidia-oot/drivers/media/i2c"
OUT="/tmp/ov9281-j401-720p${depth}-build"
BASE=/boot/tegra234-p3767-camera-p3768-ov9281-dual-j401.dtbo
mkdir -p "$OUT/nvidia-oot/drivers/media/i2c"
mkdir -p "$OUT/nvidia-oot/drivers/media/platform/tegra/camera"
cp "$SRC/nv_ov9281.c" "$OUT/nvidia-oot/drivers/media/i2c/"
cp "$SRC/ov9281_mode_tbls.h" "$OUT/nvidia-oot/drivers/media/i2c/"
cp "$L4T/nvidia-oot/drivers/media/platform/tegra/camera/camera_gpio.h" "$OUT/nvidia-oot/drivers/media/platform/tegra/camera/"
cat > "$OUT/nvidia-oot/drivers/media/i2c/Makefile" <<'EOF'
obj-m += nv_ov9281.o
ccflags-y += -I/home/nvidia/l4t/r36.4.7/nvidia-oot/include -I/home/nvidia/l4t/r36.4.7/out/nvidia-conftest -Werror
EOF
patch --batch -d "$OUT" -p1 < "$ROOT/scripts/ov9281/controls.patch" >/tmp/ov9281-720p${depth}-patch.log || true
grep -q 'OV9281_DEFAULT_FRAME_LENGTH' "$OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.c"
python3 - "$OUT/nvidia-oot/drivers/media/i2c/ov9281_mode_tbls.h" "$OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.c" "$depth" <<'PY'
import sys
header, driver, depth = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = open(header).read()
if depth == 8: s = s.replace('{0x030d, 0x50},', '{0x030d, 0x60},', 1)
for a, b in {
 '0x3803, 0x00':'0x3803, 0x28', '0x3806, 0x02':'0x3806, 0x03',
 '0x3807, 0xdf':'0x3807, 0x07', '0x380c, 0x05':'0x380c, 0x02',
 '0x380d, 0xfa':'0x380d, 0xd8', '0x380e, 0x06':'0x380e, 0x03',
 '0x380f, 0xce':'0x380f, 0x8e', '0x3820, 0x3c':'0x3820, 0x40',
 '0x3821, 0x84':'0x3821, 0x00', '0x4008, 0x02':'0x4008, 0x04',
 '0x4009, 0x05':'0x4009, 0x0b', '0x400d, 0x03':'0x400d, 0x07',
 '0x4509, 0x80':'0x4509, 0x00'}.items():
 s = s.replace(a, b, 1)
s = s.replace('static const ov9281_reg ov9281_mode_1280x720[] = {', 'static const ov9281_reg ov9281_mode_1280x720[] = {\n\t{0x3662, 0x%02x},' % (0x07 if depth == 8 else 0x05), 1)
s = s.replace('static const int ov9281_60_fr[] = {\n\t60,\n};', 'static const int ov9281_60_fr[] = {\n\t60, 120,\n};')
s = s.replace('ov9281_60_fr, 1, 0, OV9281_MODE_1280x720_8', 'ov9281_60_fr, 2, 0, OV9281_MODE_1280x720_8')
open(header, 'w').write(s)
d = open(driver).read().replace('#define OV9281_DEFAULT_FRAME_LENGTH 1742U', '#define OV9281_DEFAULT_FRAME_LENGTH 910U', 1)
open(driver, 'w').write(d)
PY
make -C /lib/modules/$(uname -r)/build M="$OUT/nvidia-oot/drivers/media/i2c" KBUILD_EXTRA_SYMBOLS="$L4T/nvidia-oot/Module.symvers" modules
dtc -I dtb -O dts -o "$OUT/base.dts" "$BASE"
python3 - "$OUT/base.dts" "$OUT/overlay.dts" "$depth" <<'PY'
import sys
src, dst, depth = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
s = s.replace('csi_pixel_bit_depth = "10"', f'csi_pixel_bit_depth = "{depth}"')
s = s.replace('line_length = "1530"', 'line_length = "728"')
s = s.replace('pix_clk_hz = "160000000"', 'pix_clk_hz = "80000000"')
s = s.replace('min_framerate = "2000000"', 'min_framerate = "60000000"')
s = s.replace('max_framerate = "60000000"', 'max_framerate = "120000000"')
s = s.replace('default_framerate = "60000000"', 'default_framerate = "120000000"')
open(dst, 'w').write(s)
PY
dtc -@ -I dts -O dtb -o "$OUT/tegra234-p3767-camera-p3768-ov9281-dual-j401-720p${depth}bit.dtbo" "$OUT/overlay.dts"
cp "$OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.ko" "$OUT/nv_ov9281-720p${depth}.ko"
echo "Built $OUT/nv_ov9281-720p${depth}.ko"
echo "Built $OUT/tegra234-p3767-camera-p3768-ov9281-dual-j401-720p${depth}bit.dtbo"
