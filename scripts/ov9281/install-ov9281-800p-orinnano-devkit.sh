#!/bin/bash
# Install the built OV9281 800p/120fps devkit module+overlay, with backups.
# Only repoints the DEFAULT boot entry (LABEL JetsonIO) at the new overlay --
# LABEL new (stock 720p8bit overlay) and LABEL primary (no camera overlay at
# all) are left untouched as reboot fallbacks. Does not reboot; run
# `sudo /sbin/reboot` yourself once this prints success.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }

build=${1:-/tmp/ov9281-800p-orinnano-devkit-build}
ovl=tegra234-p3767-camera-p3768-ov9281-dual-orinnano-devkit-800p10bit
kernel=$(uname -r)
[[ $kernel == 5.15.148-tegra ]] || { echo "This build targets 5.15.148-tegra, running kernel is $kernel." >&2; exit 1; }

module=/lib/modules/$kernel/updates/drivers/media/i2c/nv_ov9281.ko
overlay=/boot/$ovl.dtbo
extlinux=/boot/extlinux/extlinux.conf

[[ -f $build/nvidia-oot/drivers/media/i2c/nv_ov9281.ko ]] || { echo "Missing $build/nvidia-oot/drivers/media/i2c/nv_ov9281.ko -- run build-ov9281-800p-orinnano-devkit.sh first." >&2; exit 1; }
[[ -f $build/$ovl.dtbo ]] || { echo "Missing $build/$ovl.dtbo -- run build-ov9281-800p-orinnano-devkit.sh first." >&2; exit 1; }

backup=$(mktemp -d /boot/ov9281-before-800p-devkit.XXXXXX)
echo "Backup dir: $backup"

# Module: may not exist yet on a fresh board -- back it up only if present.
if [[ -f $module ]]; then
    cp -a "$module" "$backup/nv_ov9281.ko.orig"
    had_module=1
else
    had_module=0
fi
cp -a "$extlinux" "$backup/extlinux.conf.orig"

cat > "$backup/restore.sh" <<EOF
#!/bin/bash
set -euo pipefail
if [[ $had_module -eq 1 ]]; then
    cp -a '$backup/nv_ov9281.ko.orig' '$module'
else
    rm -f '$module'
fi
cp -a '$backup/extlinux.conf.orig' '$extlinux'
depmod -a '$kernel'
echo 'Original module + extlinux.conf restored. Reboot to activate.'
EOF
chmod +x "$backup/restore.sh"

restore_on_error() {
    echo 'Installation failed; restoring original files.' >&2
    bash "$backup/restore.sh"
}
trap restore_on_error ERR

# ---- install module ----
install -D -m 0644 "$build/nvidia-oot/drivers/media/i2c/nv_ov9281.ko" "$module"
depmod -a "$kernel"

# ---- install overlay (new filename, does not touch the stock dtbo) ----
install -m 0644 "$build/$ovl.dtbo" "$overlay"

# ---- repoint only the LABEL JetsonIO block's OVERLAYS line ----
python3 - "$extlinux" "$overlay" <<'PY'
import sys
path, new_overlay = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)
out = []
in_jetsonio = False
changed = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith('LABEL JetsonIO'):
        in_jetsonio = True
    elif stripped.startswith('LABEL '):
        in_jetsonio = False
    if in_jetsonio and stripped.startswith('OVERLAYS ') and not stripped.startswith('#'):
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}OVERLAYS {new_overlay}\n")
        changed = True
    else:
        out.append(line)
if not changed:
    sys.exit("Could not find an active OVERLAYS line inside LABEL JetsonIO -- not modifying extlinux.conf.")
open(path, 'w').writelines(out)
PY

trap - ERR
printf '\nInstalled OV9281 800p devkit module + overlay.\n'
printf 'Backup: %s\n' "$backup"
printf 'Rollback: sudo bash %s/restore.sh\n' "$backup"
echo
grep -n "LABEL JetsonIO\|OVERLAYS\|LABEL new\|LABEL primary\|DEFAULT" "$extlinux"
echo
echo "Review the OVERLAYS line above under 'LABEL JetsonIO' -- it should now"
echo "point at $overlay"
echo "Then: sudo /sbin/reboot"
