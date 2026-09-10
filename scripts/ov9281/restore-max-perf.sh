#!/usr/bin/env bash
# Undo set-max-perf.sh: restore BOTH the power mode and the clock state it saved.
#
# The power mode is the part that is easy to forget -- jetson_clocks --restore
# puts governors and frequencies back, but leaves the board in whatever nvpmodel
# mode was last selected. Restoring only the clocks silently leaves a board
# parked in the benchmark's power mode.
#
# Usage: sudo ./restore-max-perf.sh [statefile]
#   statefile : the path given to set-max-perf.sh (default /etc/j401_perf_state)
set -euo pipefail

STATE="${1:-/etc/j401_perf_state}"

if [[ $EUID -ne 0 ]]; then
  echo "This script changes the power mode and must run as root:" >&2
  echo "  sudo $0 $*" >&2
  exit 1
fi

if [[ ! -f "$STATE" ]]; then
  echo "No saved state at '$STATE'." >&2
  echo "If it was saved elsewhere, pass the path as the first argument." >&2
  echo "Otherwise pick a mode by hand from:" >&2
  sed -n 's/^< *POWER_MODEL *ID=\([0-9]\+\) *NAME=\(.*[^ ]\) *>$/      \1 \2/p' \
    /etc/nvpmodel.conf >&2
  exit 1
fi

# The state file also carries ENGINE lines, which are not shell assignments --
# read the two variables explicitly rather than sourcing the whole file.
MODE_ID=$(sed -n 's/^MODE_ID=//p' "$STATE" | head -1)
MODE_NAME=$(sed -n 's/^MODE_NAME=//p' "$STATE" | head -1)

if [[ -f "$STATE.clocks" ]]; then
  echo "==> Restoring clock state from $STATE.clocks"
  jetson_clocks --restore "$STATE.clocks"
else
  echo "==> No saved clock file ($STATE.clocks); leaving clocks as they are." >&2
fi

# --- fixed-function engines (restore before the power mode) ------------------
BPMP=/sys/kernel/debug/bpmp/debug/clk
if grep -q '^ENGINE ' "$STATE" 2>/dev/null; then
  echo "==> Releasing fixed-function engine clocks"
  while read -r _ name orig_rate orig_lock; do
    dir="$BPMP/$name"
    [[ -d "$dir" ]] || continue
    # Put the rate back while still locked, then restore the lock flag itself;
    # writing 0 to mrq_rate_locked hands the clock back to DVFS.
    [[ -n "$orig_rate" ]] && echo "$orig_rate" > "$dir/rate" 2>/dev/null || true
    [[ -n "$orig_lock" ]] && echo "$orig_lock" > "$dir/mrq_rate_locked" 2>/dev/null || true
    printf '      %-20s restored\n' "$name"
  done < <(grep '^ENGINE ' "$STATE")
fi

if [[ -n "$MODE_ID" ]]; then
  echo "==> Restoring power mode ${MODE_NAME:-?} (id $MODE_ID)"
  nvpmodel -m "$MODE_ID"
else
  echo "==> No saved power mode recorded; leaving the current mode alone." >&2
fi

echo "==> Now:"
nvpmodel -q 2>/dev/null | sed 's/^/      /'
printf '      CPU %s MHz, governor %s\n' \
  "$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))" \
  "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
