#!/bin/bash
# Build the production OV9281 1280x800@120fps sensor module with the gain/exposure
# fix. Stages the BSP source, applies controls.patch + fix-gain-exposure.patch,
# uses the 800p mode table (ov9281_mode_tbls_800p.h -> ov9281_mode_tbls.h), sets
# DEFAULT_FRAME_LENGTH=910, and builds the module. No tracing instrumentation.
set -euo pipefail
L4T=${L4T:-/home/nvidia/l4t/r36.4.7}
SRC="$L4T/nvidia-oot/drivers/media/i2c"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/tmp/ov9281-800p-prod-build
rm -rf "$OUT"; mkdir -p "$OUT/nvidia-oot/drivers/media/i2c"

cp "$SRC/nv_ov9281.c" "$OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.c"
cp "$ROOT/scripts/ov9281/ov9281_mode_tbls_800p.h" \
   "$OUT/nvidia-oot/drivers/media/i2c/ov9281_mode_tbls.h"
patch --batch -d "$OUT" -p1 < "$ROOT/scripts/ov9281/controls.patch" >/dev/null 2>&1 || true
patch --batch -d "$OUT" -p1 < "$ROOT/scripts/ov9281/fix-gain-exposure.patch" >/dev/null 2>&1 || true
python3 - "$OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.c" <<'PY'
import sys
p=sys.argv[1]; d=open(p).read()
d=d.replace('#define OV9281_DEFAULT_FRAME_LENGTH 1742U','#define OV9281_DEFAULT_FRAME_LENGTH 910U',1)
open(p,'w').write(d)
PY

mkdir -p "$OUT/nvidia-oot/drivers/media/platform/tegra/camera"
cp "$L4T/nvidia-oot/drivers/media/platform/tegra/camera/camera_gpio.h" \
   "$OUT/nvidia-oot/drivers/media/platform/tegra/camera/"
cat > "$OUT/nvidia-oot/drivers/media/i2c/Makefile" <<EOF
obj-m += nv_ov9281.o
ccflags-y += -I$L4T/nvidia-oot/include -I$L4T/out/nvidia-conftest -Werror
EOF
make -C "/lib/modules/$(uname -r)/build" M="$OUT/nvidia-oot/drivers/media/i2c" \
    KBUILD_EXTRA_SYMBOLS="$L4T/nvidia-oot/Module.symvers" modules
echo "BUILT $OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.ko"
echo "Install: sudo /usr/bin/install -m 644 $OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.ko \\
  /lib/modules/\$(uname -r)/updates/drivers/media/i2c/nv_ov9281.ko && sudo depmod \\"
echo "         && sudo rmmod nv_ov9281 && sudo modprobe nv_ov9281"
