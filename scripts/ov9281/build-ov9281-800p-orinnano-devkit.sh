#!/bin/bash
# Build the OV9281 1280x800@120fps stack for the NVIDIA Orin Nano/NX
# Developer Kit (P3768 carrier + P3767 module):
#   1) the DT overlay (tegra234-p3767-camera-p3768-ov9281-dual-orinnano-devkit-800p10bit.dtbo)
#   2) the sensor module (nv_ov9281.ko) with the gain/exposure fix.
#
# This overlay carries over the verified 800p/120fps mode timing and register
# table from the J4012 build (build-ov9281-800p-j401.sh), but keeps THIS
# board's own CSI wiring (tegra_sinterface/port-index/lane_polarity/
# discontinuous_clk), taken from this devkit's own stock jetson-io.py-
# generated "Camera OV9281 Dual" overlay. Do NOT reuse the J401 overlay's
# serial_a/port-index-0/lane_polarity-0 values here -- CAM0 is wired to a
# different CSI PHY (serial_b) on this carrier.
#
# Requires an L4T source tree with nvidia-oot's nv_ov9281.c + camera_gpio.h +
# Module.symvers matching the running kernel (5.15.148-tegra). Default below
# points at this board's local checkout; override with L4T=... if yours
# differs. The kernel is built separately via the repo's make_kernel.sh /
# make_kernel_modules.sh.
set -euo pipefail
L4T=${L4T:-/home/nvidia/l4t/r36.4.3/Linux_for_Tegra/source}
SRC="$L4T/nvidia-oot/drivers/media/i2c"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OVL=tegra234-p3767-camera-p3768-ov9281-dual-orinnano-devkit-800p10bit
OUT=/tmp/ov9281-800p-orinnano-devkit-build
rm -rf "$OUT"; mkdir -p "$OUT/nvidia-oot/drivers/media/i2c"

# ---- 1) DT overlay (self-contained source committed in this repo) ----
echo "== building dtbo: $OVL.dtbo =="
dtc -@ -I dts -O dtb -o "$OUT/$OVL.dtbo" "$ROOT/scripts/ov9281/$OVL.dts"
echo "   -> $OUT/$OVL.dtbo"
echo "   install to /boot/$OVL.dtbo (and point extlinux OVERLAYS at it), reboot."

# ---- 2) sensor module (same mode table / patches as the J401 build --
#          these are board-independent; only the DT overlay above differs) ----
echo "== building nv_ov9281.ko =="
cp "$SRC/nv_ov9281.c" "$OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.c"
cp "$ROOT/scripts/ov9281/ov9281_mode_tbls_800p.h" \
   "$OUT/nvidia-oot/drivers/media/i2c/ov9281_mode_tbls.h"
# controls.patch also carries a leftover DTS hunk from an earlier combined
# patch; it always fails/skips here (we handle the DT overlay separately) --
# that failure is expected and harmless, hence the `|| true`.
patch --batch -d "$OUT" -p1 < "$ROOT/scripts/ov9281/controls.patch" >/dev/null 2>&1 || true
# fix-gain-exposure.patch's diff header uses stale /tmp/... paths (not
# nvidia-oot/... ), so it must be applied by explicit filename -- `-d "$OUT" -p1`
# silently no-ops. This one is NOT optional: it's the actual gain/exposure
# persistence fix, so let it fail the build loudly.
patch --batch "$OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.c" < "$ROOT/scripts/ov9281/fix-gain-exposure.patch"
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

echo "BUILT: $OUT/$OVL.dtbo  and  $OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.ko"
echo
echo "Install module:"
echo "  sudo /usr/bin/install -m 644 $OUT/nvidia-oot/drivers/media/i2c/nv_ov9281.ko \\"
echo "    /lib/modules/\$(uname -r)/updates/drivers/media/i2c/nv_ov9281.ko"
echo "  sudo /usr/sbin/depmod && sudo /sbin/rmmod nv_ov9281 && sudo /sbin/modprobe nv_ov9281"
echo "Install overlay (then reboot):"
echo "  sudo /usr/bin/install -m 644 $OUT/$OVL.dtbo /boot/$OVL.dtbo"
echo "  # then point extlinux.conf's OVERLAYS line at /boot/$OVL.dtbo"
