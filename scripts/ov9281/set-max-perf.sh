#!/usr/bin/env bash
# Lock this Jetson at maximum performance for reproducible benchmarks, and save
# enough state that restore-max-perf.sh can put it back exactly.
#
# This is the single copy of this script. It backs both the OV9281 camera-margin
# benchmarks in this repo (see measure-margin.py) and the TinyTag detector
# benchmarks in the sibling tinytag_orin repo, which used to carry a duplicate.
#
# Board-agnostic: the max-performance power mode is looked up BY NAME in
# /etc/nvpmodel.conf, never hardcoded. This matters because the ID differs
# between boards:
#
#   Orin NX                : ID 0 = MAXN
#   Orin Nano Super devkit : ID 0 = 15W, ID 1 = 25W, ID 2 = MAXN_SUPER
#
# A script that hardcodes `nvpmodel -m 0` therefore *downgrades* an Orin Nano
# Super to 15W -- capping the GPU at 612MHz against 1020MHz of silicon -- while
# appearing to do the opposite. README section 19 covers why that invalidates
# any GPU-vs-CPU comparison taken in that state.
#
# Beyond CPU/GPU/EMC (all `jetson_clocks` and nvpmodel actually cover), this
# also pins the fixed-function engines -- DLA, PVA, NVENC, NVDEC, NVJPG, VIC,
# OFA -- via the BPMP debugfs clock interface, for whichever of them the board
# has. They are DISCOVERED, not hardcoded: an Orin Nano has no DLA, no PVA and
# no NVENC, while an Orin NX has all of them.
#
# Usage: sudo ./set-max-perf.sh [statefile] [--no-engines]
#   statefile   : where to save the pre-lock state (default /etc/j401_perf_state).
#                 Under /etc so it survives a reboot mid-benchmark; the older
#                 /etc/j401_l4t_dfs.conf held only jetson_clocks state and is
#                 not read by this version.
#   --no-engines: pin CPU/GPU/EMC only, leave the fixed-function engines alone
set -euo pipefail

STATE="/etc/j401_perf_state"
DO_ENGINES=1
for arg in "$@"; do
  case "$arg" in
    --no-engines) DO_ENGINES=0 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) STATE="$arg" ;;
  esac
done
CONF=/etc/nvpmodel.conf
BPMP=/sys/kernel/debug/bpmp/debug/clk
# Fixed-function engine clocks worth pinning. Matched against the BPMP clock
# names present on the board, so absent engines are simply skipped.
ENGINE_RE='^(nafll_)?(dla[0-9]*(_core|_falcon)?|pva[0-9]*(_vps|_core)?|nvenc|nvdec|nvjpg[0-9]*|vic|ofa|se)$' 

if [[ $EUID -ne 0 ]]; then
  echo "This script changes the power mode and must run as root:" >&2
  echo "  sudo $0 $*" >&2
  exit 1
fi

[[ -r "$CONF" ]] || { echo "cannot read $CONF" >&2; exit 1; }

# --- enumerate the modes this board actually defines ------------------------
modes=$(sed -n 's/^< *POWER_MODEL *ID=\([0-9]\+\) *NAME=\(.*[^ ]\) *>$/\1 \2/p' "$CONF")
[[ -n "$modes" ]] || { echo "no POWER_MODEL entries found in $CONF" >&2; exit 1; }

echo "==> Power modes on this board:"
echo "$modes" | sed 's/^/      /'

# Prefer a mode whose name starts with MAXN (MAXN, MAXN_SUPER, ...).
target_id=$(echo "$modes" | awk '$2 ~ /^MAXN/ {print $1; exit}')
target_name=$(echo "$modes" | awk '$2 ~ /^MAXN/ {print $2; exit}')
if [[ -z "$target_id" ]]; then
  echo "No MAXN* mode defined on this board; refusing to guess." >&2
  echo "Pick one from the list above and run: nvpmodel -m <id>" >&2
  exit 1
fi

# --- remember where we came from --------------------------------------------
# `nvpmodel -q` prints the mode name, then the numeric id on its own line.
current_id=$(nvpmodel -q 2>/dev/null | awk '/^[0-9]+$/ {print; exit}')
current_name=$(nvpmodel -q 2>/dev/null | sed -n 's/^NV Power Mode: *//p' | head -1)
: "${current_id:=}"

echo "==> Current mode: ${current_name:-unknown} (id ${current_id:-unknown})"
echo "==> Target mode : $target_name (id $target_id)"

mkdir -p "$(dirname "$STATE")"
printf 'MODE_ID=%s\nMODE_NAME=%s\n' "${current_id:-}" "${current_name:-}" > "$STATE"

# jetson_clocks --store refuses to overwrite, so clear a stale file first;
# a re-run should always capture the current pre-lock state.
rm -f "$STATE.clocks"
jetson_clocks --store "$STATE.clocks"
echo "==> Saved previous state to $STATE and $STATE.clocks"

# --- lock --------------------------------------------------------------------
if [[ "${current_id:-}" != "$target_id" ]]; then
  echo "==> Switching to $target_name"
  nvpmodel -m "$target_id"
else
  echo "==> Already in $target_name"
fi

# Pin CPU/GPU/EMC at that mode's maximum. Deliberately NOT `jetson_clocks --fan`:
# that forces the fan to 100%. Left to nvfancontrol, which ramps adaptively.
echo "==> Pinning CPU/GPU/EMC to static max"
jetson_clocks

# --- report ------------------------------------------------------------------
echo "==> Now:"
nvpmodel -q 2>/dev/null | sed 's/^/      /'
for gpu in /sys/devices/*.ga10b/devfreq/*.ga10b /sys/devices/platform/bus@0/*.gpu/devfreq/*.gpu; do
  [[ -r "$gpu/cur_freq" ]] || continue
  printf '      GPU %s MHz (max %s MHz)\n' \
    "$(( $(cat "$gpu/cur_freq") / 1000000 ))" "$(( $(cat "$gpu/max_freq") / 1000000 ))"
  break
done
printf '      CPU %s MHz, governor %s\n' \
  "$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))" \
  "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

# --- fixed-function engines --------------------------------------------------
# jetson_clocks covers CPU, GPU and EMC only, and nvpmodel's MAXN entry sets
# nothing else either (see the MAX_FREQ -1 lines in nvpmodel.conf). Everything
# else is pinned through BPMP: lock the rate, then write the clock's own
# max_rate into it.
if [[ "$DO_ENGINES" -eq 1 ]]; then
  if [[ ! -d "$BPMP" ]]; then
    echo "==> BPMP debugfs not available at $BPMP; skipping engine clocks." >&2
    echo "    (mount -t debugfs none /sys/kernel/debug, or pass --no-engines)" >&2
  else
    echo "==> Pinning fixed-function engine clocks"
    pinned=0 skipped=""
    for dir in "$BPMP"/*; do
      [[ -d "$dir" ]] || continue
      name=$(basename "$dir")
      [[ "$name" =~ $ENGINE_RE ]] || continue
      if [[ ! -r "$dir/max_rate" || ! -w "$dir/rate" ]]; then
        skipped+=" $name"
        continue
      fi
      max=$(cat "$dir/max_rate" 2>/dev/null) || { skipped+=" $name"; continue; }
      [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || { skipped+=" $name"; continue; }
      orig_rate=$(cat "$dir/rate" 2>/dev/null || echo "")
      orig_lock=$(cat "$dir/mrq_rate_locked" 2>/dev/null || echo "")
      # Record before touching anything, so restore works even on partial failure.
      printf 'ENGINE %s %s %s\n' "$name" "${orig_rate:-}" "${orig_lock:-}" >> "$STATE"
      echo 1 > "$dir/mrq_rate_locked" 2>/dev/null || true
      if echo "$max" > "$dir/rate" 2>/dev/null; then
        printf '      %-20s %s MHz\n' "$name" "$(( max / 1000000 ))"
        pinned=$(( pinned + 1 ))
      else
        skipped+=" $name"
      fi
    done
    echo "      pinned $pinned engine clock(s)"
    # Plain `[[ ... ]] && echo` would abort the script under `set -e` whenever
    # the condition is false, since the AND-list itself then returns non-zero.
    if [[ -n "$skipped" ]]; then
      echo "      skipped (not settable):$skipped"
    fi
    if [[ "$pinned" -eq 0 ]]; then
      echo "      (this board may simply have no DLA/PVA/NVENC -- an Orin Nano has none)"
    fi
  fi
fi

echo "==> Undo with: sudo $(dirname "$0")/restore-max-perf.sh '$STATE'"
