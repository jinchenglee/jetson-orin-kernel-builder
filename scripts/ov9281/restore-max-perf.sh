#!/usr/bin/env bash
# restore-max-perf.sh - Restore the pre-lock power/clock state saved by
# set-max-perf.sh, returning CPU/GPU/EMC to their original governors/frequencies.
#
# Usage:  sudo ./restore-max-perf.sh [savefile]
#   savefile : path used earlier with set-max-perf.sh (default /etc/j401_l4t_dfs.conf)
#
# Requires root.
set -euo pipefail

SAVED="${1:-/etc/j401_l4t_dfs.conf}"

if [[ -f "$SAVED" ]]; then
    echo "==> Restoring clock state from $SAVED"
    jetson_clocks --restore "$SAVED"
    echo "==> Restored. Verify: jetson_clocks --show"
    echo "    (CPU governor should be back to the saved value, e.g. schedutil, and clocks free-running.)"
else
    echo "No saved clock state at '$SAVED'." >&2
    echo "If a state file exists elsewhere, pass it as the first argument." >&2
    exit 1
fi

echo "==> If you changed the power mode with nvpmodel, restore it explicitly, e.g.:"
echo "    sudo nvpmodel -m <orig-mode-id>   (this board default is MAXN / 0)"
