#!/bin/bash
# Install the built OV9281 800p/120fps J4012 module+overlay, with backups.
# Mirrors install-ov9281-800p-orinnano-devkit.sh. Does not reboot; run
# `sudo /sbin/reboot` yourself once this prints success.
#
# Difference from the devkit installer: that one hardcodes "LABEL JetsonIO"
# (the label jetson-io.py generates on the NVIDIA devkit). The J4012's
# extlinux.conf is not necessarily laid out that way, so this reads the
# DEFAULT label out of extlinux.conf and repoints only that entry's OVERLAYS
# line -- every other LABEL block is left untouched as a reboot fallback.
#
# NOTE: unlike the devkit script, this one has NOT been run end-to-end on
# real J4012 hardware. It is the same logic, but check the extlinux.conf
# summary it prints before rebooting.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }

build=${1:-/tmp/ov9281-800p-prod-build}
ovl=tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit
kernel=$(uname -r)
[[ $kernel == 5.15.148-tegra ]] || { echo "This build targets 5.15.148-tegra, running kernel is $kernel." >&2; exit 1; }

module=/lib/modules/$kernel/updates/drivers/media/i2c/nv_ov9281.ko
overlay=/boot/$ovl.dtbo
extlinux=/boot/extlinux/extlinux.conf

[[ -f $build/nvidia-oot/drivers/media/i2c/nv_ov9281.ko ]] || { echo "Missing $build/nvidia-oot/drivers/media/i2c/nv_ov9281.ko -- run build-ov9281-800p-j401.sh first." >&2; exit 1; }
[[ -f $build/$ovl.dtbo ]] || { echo "Missing $build/$ovl.dtbo -- run build-ov9281-800p-j401.sh first." >&2; exit 1; }

backup=$(mktemp -d /boot/ov9281-before-800p-j401.XXXXXX)
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

# ---- install overlay (own filename, does not touch any stock dtbo) ----
install -m 0644 "$build/$ovl.dtbo" "$overlay"

# ---- repoint only the DEFAULT boot entry's OVERLAYS line ----
python3 - "$extlinux" "$overlay" <<'PY'
import sys
path, new_overlay = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)

default = None
for line in lines:
    s = line.strip()
    if s.startswith('DEFAULT ') and not s.startswith('#'):
        default = s.split(None, 1)[1].strip()
if not default:
    sys.exit("No DEFAULT entry found in extlinux.conf -- not modifying it.")

out = []
in_default = False
changed = False
for line in lines:
    s = line.strip()
    if s.startswith('LABEL ') and not s.startswith('#'):
        in_default = (s.split(None, 1)[1].strip() == default)
    if in_default and s.startswith('OVERLAYS ') and not s.startswith('#'):
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}OVERLAYS {new_overlay}\n")
        changed = True
    else:
        out.append(line)

if not changed:
    sys.exit(
        "No active OVERLAYS line inside the DEFAULT entry (LABEL %s) -- not\n"
        "modifying extlinux.conf. Add this line to that block by hand, then\n"
        "reboot:\n    OVERLAYS %s" % (default, new_overlay))
open(path, 'w').writelines(out)
print("Repointed the OVERLAYS line under LABEL %s" % default)
PY

trap - ERR
printf '\nInstalled OV9281 800p J4012 module + overlay.\n'
printf 'Backup: %s\n' "$backup"
printf 'Rollback: sudo bash %s/restore.sh\n' "$backup"
echo
grep -n "DEFAULT\|LABEL\|OVERLAYS" "$extlinux"
echo
echo "Review the OVERLAYS line under the DEFAULT entry above -- it should now"
echo "point at $overlay"
echo "Then: sudo /sbin/reboot"
