# OV9281 120fps — achieved (2026-09-09)

Current verified state: **dual 1280x800 RAW10 @ 120fps working on both J401 cameras.**

## What changed from the prior handover

The prior high-speed build (720p, `pix_clk_hz=80MHz`, `line_length=728`) produced
FORCE_FE frame rejects on every frame. Root cause identified and fixed:

- **`pix_clk_hz` was wrong.** It must be the D-PHY pixel rate = link freq x lanes x
  DDR / bpp = 400MHz x 2 x 2 / 10 = **160MHz** (not 80MHz). The CSI CIL/VI config and
  the frame-rate math are driven off it; 80MHz under-clocked the receiver for the
  incoming 800 Mbps/lane stream -> `CAPTURE_CHANNEL_ERROR_FORCE_FE` (err_data 0x20000).
- **`line_length` must be the mainline doubled HTS (0x05b0 = 1456 = 2 x 728)**, not 728,
  so the frame-rate / VTS math agrees with `pix_clk_hz=160MHz`.
- The old "known-good 60fps" was actually ~30fps real: HTS=1530/VTS=1742 with the
  datasheet's 80MHz sensor clock -> 30fps, while the DT advertised 60fps (2x pixel-clock
  error). Superseded.

## Verified working configuration (installed)

- Mode: 1280x800, 10-bit RAW (`grey_y10`), HTS=0x02d8 (728), VTS=0x038e (910), pixel
  rate 160MHz -> 120.6fps.
- Register table ported from the mainline/RPi driver (6by9): mainline `common_regs`
  (incl. 0x3030=0x04, 0x4800=0x00) + `op_10bit` (0x030d=0x50, 0x3662=0x05) + the
  1280x800 mode regs (crop 0,0; 0x3820=0x40, 0x3821=0x00, 0x4509=0x00).
- DT overlay: `tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit.dtbo`
  (active_w=1280, active_h=800, line_length=1456, pix_clk_hz=160000000, 10-bit,
  framerate 60000000-120000000 default 120000000).
- Module: `nv_ov9281.ko` rebuilt with the 1280x800 mode, controls patch applied,
  `OV9281_DEFAULT_FRAME_LENGTH=910`.
- Backups: `/lib/modules/.../nv_ov9281.ko.pre-800ptest`, `/boot/extlinux/extlinux.conf.pre-800ptest`.

## Verified on hardware

- Both `/dev/video1` (CAM0, bus 10) and `/dev/video0` (CAM1, bus 9) enumerate
  1280x800 `Y10 ` @ 120fps.
- Capture: 600-frame run measures **120.63 fps**, zero `corr_err`/`uncorr_err` in the boot
  kernel log; live register readback on both sensors confirms HTS=728, VTS=910,
  0x3662=0x05, 0x030d=0x50, 0x030e=0x02, 0x4800=0x00.
- **Concurrent capture** (both cameras at once): both sustain 120.63 fps simultaneously
  (241 fps aggregate), 0 drops over 3000 frames each, 0 CSI errors.

## Sustainable fps + CPU/GPU margin (dual capture baseline)

Dual 1280x800 @120fps raw Y10, v4l2-ctl mmap to /dev/null, 3000 frames each:

| Metric | Value |
|---|---|
| Sustained fps | 120.6 / camera, 241.3 aggregate |
| Dropped frames / errors | 0 / 0 |
| Raw pixel data | ~988 MB/s |
| CPU busy (8 cores) | ~9% total (~91% idle); capture adds ~0-2% |
| GPU (GR3D) | 0% |
| Power (VDD_IN) | ~7.8 W |
| RAM used | ~2.3 GB / 15.6 GB |

Measurement overhead to note (refine later):
- `v4l2-ctl` copies every mmap'd frame to the output (a CPU memcpy). A zero-copy
  DMABUF pipeline removes it, so the CPU figure is an upper bound.
- `top`/`tegrastats` sampling overhead.
- ~9% of measured busy is the GNOME/desktop ambient, not capture.

## Live view

- GStreamer `v4l2src` cannot negotiate the tegra `grey_y10` (its V4L2 plugin maps no
  format; src caps report EMPTY) — the same monochrome gap that blocked Argus.
- Use V4L2 direct captures. Concurrent capture works: run `v4l2-ctl` on
  `/dev/video1` and `/dev/video0` in parallel and write the two Y10 streams to files
  (or pipe into a converter), then view/unpack offline. A zero-copy + convert +
  display/encode pipeline is the next step for a true live preview.

## Next steps

- Add 1280x720 as an additional selectable mode (mainline: 1280x720@144fps, VTS=761,
  crop top=40; and 800p@150fps in 8-bit). Requires driver multi-mode (mode0/mode1) +
  DT mode nodes + V4L2 format selection.

## Controls fix + live-view conversion (2026-09-09)

### Sensor data format (root cause of the "noisy / black-white" PNG)
The OV9281 tegra transport returns each 10-bit sample expanded across 16 bits:

    stored16 = (value10 << 6) | (value10 >> 4)

i.e. the 10-bit sample is in the HIGH bits, not the low bits. Converting with
`(a & 0x3ff) >> 2` (masking the low bits) produced speckled false contours.
Correct conversion:

    gray8 = (raw16 >> 8).astype(uint8)      #  or  ((raw16 >> 6) >> 2)

`measure-margin.py` was updated to use `a >> 8` everywhere (grab_frame, live
FIFO reader) and the live display now uses a float-math 1–99 percentile stretch
(the integer-division autolevel caused banding) plus a light median blur.
The correctly-converted frame is dark (the exposures occupy only part of the
10-bit range), so the stretch is needed for display.

### Gain/exposure runtime + init now take effect (verified)
The V4L2 gain/exposure controls were accepted but did not reach the sensor
reliably:
- `tegracam_set_ctrls` silently drops sensor controls when the sensor is not
  powered (`g_input_status` != SWITCH_ON) — pre-stream/init sets were lost.
- `ov9281_set_mode` only re-applied exposure from `priv->exposure_us ?: 10000`
  after the register table; gain was always reset to the table's 1x and the
  10000us default over-exposed (clamped to VTS-12 = 898/910 lines).
- Re-reading the control's current value in set_mode is unreliable (it is at its
  minimum on fresh load) → near-zero exposure.

Fix (scripts/ov9281/fix-gain-exposure.patch, applied on top of controls.patch):
- add `s64 gain` to struct ov9281; set_gain stores it (mirrors exposure_us).
- set_mode, after the register table, applies
      gain      -> priv->gain ?: mode->control_properties.default_gain
      exposure  -> priv->exposure_us ?: mode->control_properties.default_exp_time.val
  frame_rate is deliberately NOT re-applied here: rewriting VTS 0x380e/f in
  set_mode desynced the CSI receiver (corr_err FORCE_FE, err_data 0x20000).
- DT overlay: default_exp_time 10000 -> 4000us to set a sensible init exposure
  (~52% of the 8.33ms 120fps frame) instead of the blown-out 10000us.

Verified on hardware: init state 4000us/1x, runtime gain + exposure land and
persist across stream restarts, 120.63 fps/cam, 0 corr/uncorr errors.

### Traps hit (record for the next session)
- Do NOT build with the 720p sed transforms (build-j401-720p120.sh) for the
  1280x800 setup — it yields a 720p mode table vs the 800p DT overlay, and VI
  rejects every frame (FORCE_FE). Use ov9281_mode_tbls_800p.h.
- Do NOT re-apply frame_rate in set_mode (VTS rewrite -> FORCE_FE).
