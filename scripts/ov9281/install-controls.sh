#!/bin/bash
# Install the staged experimental module/overlay with backups; reboot separately.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
build=${1:-/tmp/ov9281-controls-build}
kernel=$(uname -r)
[[ $kernel == 5.15.148-tegra ]] || { echo 'This build is for 5.15.148-tegra.' >&2; exit 1; }
module=$(modinfo -n nv_ov9281)
overlay=/boot/tegra234-p3767-camera-p3768-ov9281-dual.dtbo
[[ -f $module && -f $overlay && -f $build/nv_ov9281.ko && -f $build/$(basename "$overlay") ]]
[[ $(modinfo -F vermagic "$module") == "$(modinfo -F vermagic "$build/nv_ov9281.ko")" ]]
backup=$(mktemp -d /boot/ov9281-before-controls.XXXXXX)
cp -a "$module" "$backup/nv_ov9281.ko"
cp -a "$overlay" "$backup/$(basename "$overlay")"
printf '%s\n' "$module" > "$backup/module-path.txt"
cat > "$backup/restore.sh" <<EOF
#!/bin/bash
set -euo pipefail
cp -a '$backup/nv_ov9281.ko' '$module'
cp -a '$backup/$(basename "$overlay")' '$overlay'
depmod -a '$kernel'
echo 'Original files restored. Reboot to activate them.'
EOF
restore_on_error() {
    echo 'Installation failed; restoring original files.' >&2
    bash "$backup/restore.sh"
}
trap restore_on_error ERR
install -m 0644 "$build/nv_ov9281.ko" "$module"
install -m 0644 "$build/$(basename "$overlay")" "$overlay"
depmod -a "$kernel"
trap - ERR
printf 'Installed experimental OV9281 controls. Backup: %s\n' "$backup"
printf 'Rollback: sudo bash %s/restore.sh\n' "$backup"
echo 'Reboot to activate the module and revised overlay together.'
