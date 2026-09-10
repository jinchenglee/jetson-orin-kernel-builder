#!/usr/bin/env bash
# set-max-perf.sh - Lock the Orin NX at maximum performance for reproducible
# high-load camera benchmarks (CPU/GPU/EMC static max clocks + MAXN power mode).
#
# Saves the pre-lock clock state so restore-max-perf.sh can put it back.
#
# Usage:  sudo ./set-max-perf.sh [savefile]
#   savefile : where to store the pre-lock clock state (default /etc/j401_l4t_dfs.conf)
#
# Requires root (this is why it must be run with sudo).
set -euo pipefail

SAVED="${1:-/etc/j401_l4t_dfs.conf}"

echo "==> Ensuring MAXN (maximum) power mode"
# ID 0 = MAXN on this Orin NX; already active, keep idempotent.
nvpmodel -m 0 || echo "  (nvpmodel -m 0 returned non-zero; continuing - may already be MAXN)"

echo "==> Saving current clock state to $SAVED"
# jetson_clocks --store refuses to overwrite an existing file; remove one left by
# a previous run first so a re-run always captures the current (pre-lock) state.
rm -f "$SAVED"
jetson_clocks --store "$SAVED"

echo "==> Locking CPU/GPU/EMC to static max frequency (fan stays adaptive)"
# NOTE: we intentionally do NOT call 'jetson_clocks --fan'. That forces the
# pwm-fan to 100% (noisy). The fan is instead left under nvfancontrol, which
# ramps it adaptively with the thermal zones (cpu/gpu/soc) — it will spin up on
# its own as the locked clocks raise SoC temperature.
jetson_clocks

echo "==> Done. Verify: jetson_clocks --show"
echo "    CPU governor should now be 'performance' and clocks pinned to max."
echo "    Re-run your capture/margin test now for the worst-case baseline."
echo "    Undo with: sudo ./restore-max-perf.sh '$SAVED'"
