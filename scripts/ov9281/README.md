# OV9281 dual camera bring-up (Seeed J4012 / Orin Nano Devkit)

Guide to go from a **fresh clone** of this repo (branch `ov9281`) to a working
**dual OV9281 1280x800 RAW10 @ 120fps** setup, plus the live measurement/view
scripts. Originally developed and verified on a Seeed Studio reComputer
J4012 (Orin NX 16GB); the same mode table and control fixes have also been
ported to the NVIDIA Orin Nano/NX Developer Kit's own CSI wiring — see
"Board variants" below.

The OV9281 support is entirely out-of-tree: the sensor module (`nv_ov9281.ko`)
and a Device Tree overlay (`tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit`)
are built here. The kernel itself is the stock L4T/Orin kernel and is built with
the repo's generic kernel scripts.

---

## Board variants

The 800p/120fps mode table, register sequence, and gain/exposure fixes below
are board-independent. The DT overlay's CSI wiring (`tegra_sinterface`,
CSI/VI `port-index`, `lane_polarity`, `discontinuous_clk`) is NOT — it must
match each carrier's actual physical routing, or CAM0/CAM1 will get zero CSI
frames (see "Known traps" below). Two overlay+build-script pairs exist so
far, both suffixed by board:

- `build-ov9281-800p-j401.sh` + `tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit.dts`
  — Seeed Studio reComputer J4012 (Orin NX 16GB). CAM0 = `serial_a`/port-index 0/
  lane_polarity 6/`discontinuous_clk=yes`; CAM1 = `serial_c`/port-index 2/
  lane_polarity 0/`discontinuous_clk=yes`.
- `build-ov9281-800p-orinnano-devkit.sh` + `tegra234-p3767-camera-p3768-ov9281-dual-orinnano-devkit-800p10bit.dts`
  — NVIDIA Orin Nano/NX Developer Kit (P3768 carrier + P3767 module). CAM0 =
  `serial_b`/port-index 1/lane_polarity 6/`discontinuous_clk=no`; CAM1 =
  `serial_c`/port-index 2/lane_polarity 0/`discontinuous_clk=no`. Both
  verified at 120.63 fps with 0 CSI errors. The `serial_b`/port-index values
  come from this board's own stock jetson-io.py-generated "Camera OV9281
  Dual" overlay, NOT from the J401 file (its `serial_a`/port-index-0 CAM0
  mapping targets a different CSI PHY on this carrier) — but see the
  `lane_polarity` warning below before trusting that stock overlay wholesale.

**Do not trust the stock OV9281 overlay's `serial_c` `lane_polarity`.** It
ships as `1`; the correct value for this connector is `0`, and with `1` the
CAM1 channel gets zero CSI frames (`uncorr_err` timeouts) while its I2C probe
still succeeds perfectly. `lane_polarity` describes PCB trace routing (whether
P/N are swapped on the connector), so it cannot legitimately vary by sensor —
yet NVIDIA's own overlays for these same two connectors disagree:

| stock overlay | `serial_b` | `serial_c` |
|---|---|---|
| `imx219-dual` | 6 | *(absent → 0)* |
| `imx477-dual` | 6 | 0 |
| `ov9281-dual` | 6 | **1** ← wrong |

IMX219/IMX477 are the well-tested profiles on this devkit and both agree on 0
(as does this repo's verified J401 overlay), so the OV9281 profile's `1` is a
bug in a profile that was evidently never validated past the I2C probe.

Porting to a third carrier: decompile that board's own working stock overlay
(`dtc -I dtb -O dts your.dtbo`) if one exists, or derive routing from the
vendor's factory device-tree/schematic (see the CAM0-routing story in "Known
traps"), copy one of the two `.dts` files above, keep every wiring field from
the new board's own source, and only carry over the mode-table/timing/control
fields (`active_h`, `csi_pixel_bit_depth`, `line_length`, `pix_clk_hz`,
`*_factor`, `*_gain_val`, `*_framerate`, `*_exp_time`) from this repo's 800p
config. Add a matching board-suffixed build script. Cross-check every wiring
field against two or three of that board's other stock camera overlays --
routing fields must agree across all of them, and one that disagrees is a bug
in the less-tested profile, not a sensor-specific value.

---

## What you get

- Both J401 camera ports enumerated as `1280x800 Y10` @ 120 fps:
  - `/dev/video1` = CAM0 (J401 CSI0, `serial_a`, bus 10, addr 0x60)
  - `/dev/video0` = CAM1 (J401 CSI2, `serial_c`, bus 9, addr 0x60)
- Verified: 120.63 fps per camera (241 fps aggregate), 0 CSI errors.
- V4L2 `gain` / `exposure` / `frame_rate` controls that actually take effect
  (runtime AND at init, persisting across streams).
- `measure-margin.py` — dual-capture throughput / CPU margin benchmark and a
  side-by-side **live view**.

---

## Hardware / software requirements

- Seeed Studio reComputer J4012 carrier with an Orin NX 16GB (JetPack 6 / L4T
  36.4.x, kernel `5.15.148-tegra`).
- Two OV9281 camera modules on CAM0 and CAM1.
- `git`, `dtc`, and the kernel build toolchain (installed by the JetPack SDK /
  `get_kernel_sources.sh`).

---

## Step 1 — clone and get the L4T sources

On the board:

```bash
git clone <your-fork-of-jetson-orin-kernel-builder>
cd jetson-orin-kernel-builder
git checkout ov9281
```

Fetch the Jetson L4T kernel / out-of-tree module sources. The generic script
downloads and configures them:

```bash
./scripts/get_kernel_sources.sh --force-replace      # interactive / or force
```

This puts the kernel and the `nvidia-oot` tree (which contains the tegra camera
framework + `nv_ov9281.c`) under `/usr/src`. Point the OV9281 build at it. On the
reference J4012 board the sources are staged at:

```bash
export L4T=/home/nvidia/l4t/r36.4.7
```

If you used `get_kernel_sources.sh` instead, point `L4T` at that directory (it
must contain `nvidia-oot/drivers/media/i2c/nv_ov9281.c` AND
`nvidia-oot/Module.symvers`, plus the kernel headers for `make -C
/lib/modules/$(uname -r)/build`).

> Kernel build (optional, only if you change the kernel): `./scripts/make_kernel.sh`
> and `./scripts/make_kernel_modules.sh`. The OV9281 module builds on top of the
> running L4T kernel.

---

## Step 2 — build the overlay + module

Pick the script matching your carrier (see "Board variants" above):

```bash
cd scripts/ov9281
bash build-ov9281-800p-j401.sh              # Seeed J4012
# or
bash build-ov9281-800p-orinnano-devkit.sh   # NVIDIA Orin Nano/NX Devkit
```

That produces both, in `/tmp/ov9281-800p-prod-build/` (J401 script) or
`/tmp/ov9281-800p-orinnano-devkit-build/` (devkit script):

- `tegra234-p3767-camera-p3768-ov9281-dual-<board>-800p10bit.dtbo`
- `nvidia-oot/drivers/media/i2c/nv_ov9281.ko`

The build applies (in order): the 800p mode table (`ov9281_mode_tbls_800p.h`),
`controls.patch` (control factors / ranges / defaults) and
`fix-gain-exposure.patch` (so gain & exposure set at init AND runtime actually
reach the sensor and persist across streams). `DEFAULT_FRAME_LENGTH` is set to
910 (VTS) for the 120 fps mode.

---

## Step 3 — install and reboot

Use the installer matching your carrier:

```bash
sudo bash install-ov9281-800p-j401.sh              # Seeed J4012
# or
sudo bash install-ov9281-800p-orinnano-devkit.sh   # NVIDIA Orin Nano/NX Devkit

sudo /sbin/reboot
```

Each one installs the module (plus `depmod`) and the overlay, then repoints
only the DEFAULT boot entry's `OVERLAYS` line at the new overlay — every
other `LABEL` block is left alone as a reboot fallback. Both back up the
previous module and `extlinux.conf` to `/boot/ov9281-before-800p-*.XXXXXX/`
with a `restore.sh` next to them, and neither reboots for you. If anything
fails partway they roll back automatically. Pass a build directory as `$1` if
you did not build to the default location.

The DT overlay change needs a reboot; the module change can be applied without
one (`sudo /sbin/rmmod nv_ov9281 && sudo /sbin/modprobe nv_ov9281`).

To do it by hand instead:

```bash
MOD=/lib/modules/$(uname -r)/updates/drivers/media/i2c/nv_ov9281.ko
sudo /usr/bin/install -m 644 \
  /tmp/ov9281-800p-prod-build/nvidia-oot/drivers/media/i2c/nv_ov9281.ko "$MOD"
sudo /usr/sbin/depmod
sudo /usr/bin/install -m 644 \
  /tmp/ov9281-800p-prod-build/tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit.dtbo \
  /boot/tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit.dtbo

# ensure extlinux OVERLAYS points at the 800p10bit overlay, then reboot
sudo /sbin/reboot
```

---

## Step 4 — verify

```bash
v4l2-ctl --list-devices | grep -i ov9281
v4l2-ctl -d /dev/video0 --get-fmt-video        # expect 1280x800 'Y10 '
v4l2-ctl -d /dev/video0 --list-ctrls           # gain/exposure/frame_rate present
# 60-frame capture on each camera (2,048,000 bytes/flame = 1280x800x2)
timeout 8 v4l2-ctl -d /dev/video0 --set-fmt-video='width=1280,height=800,pixelformat=Y10 ' \
  --set-ctrl=frame_rate=120000000 --stream-mmap --stream-count=60 --stream-to=/dev/null
# no corr_err / uncorr_err expected:
sudo dmesg | grep -Ei 'corr_err|uncorr_err' || echo "clean"
```

---

## Step 5 — run the measurement / live view

Bare dual-capture benchmark:

```bash
python3 measure-margin.py --seconds 10
```

Live view (needs a display session):

```bash
# within the desktop session (DISPLAY set); else use --live-save-dir for PNGs
python3 measure-margin.py --live
python3 measure-margin.py --live --live-save-dir /tmp/liveout --seconds 5   # headless snapshots
```

Shows both cameras side by side if both CAM0/CAM1 are wired, or a single pane
if only one is (checks which `/dev/video*` nodes actually exist -- a camera
with nothing wired to its CSI port never gets a device node and no longer
blocks the other camera's display). The per-frame contrast stretch/median
blur/color conversion runs on the GPU via `cv2.cuda` when the installed
OpenCV has CUDA support (check with `python3 -c "import cv2;
print(cv2.cuda.getCudaEnabledDeviceCount())"`), falling back to the
equivalent CPU/numpy path otherwise.

Runtime control override during a live/continuous stream (works and persists):

```bash
v4l2-ctl -d /dev/video1 --set-ctrl=exposure=5000 --set-ctrl=gain=100
```

---

## Notes / known traps

- **Data format**: the tegra monochrome `Y10` transport places the 10-bit sample
  in the **high** 10 bits (`stored16 = (v<<6) | (v>>4)`). Convert with
  `gray8 = (raw16 >> 8)` (equivalently `(raw16>>6)>>2`). Do **not** use
  `(a & 0x3ff) >> 2` — that reads the low (fractional/noise) bits and produces
  speckled false contours. `measure-margin.py` already does `a >> 8` and uses a
  float 1–99% stretch + median blur for the live display (the correctly
  converted frame is dark because the exposures only span part of the range).
- **Controls gating**: the tegra framework silently drops sensor controls when
  the sensor is not powered (set before streaming). `fix-gain-exposure.patch`
  makes `set_mode` re-apply gain/exposure after the register table so init and
  pre-stream settings survive; runtime sets are applied immediately.
- **Do not** build this 800p setup with the 720p sed transforms
  (`build-j401-720p120.sh`): it yields a 720p mode table vs the 800p overlay and
  the CSI receiver rejects every frame (`corr_err err_data 0x20000`, FORCE_FE).
- **Do not** re-apply `frame_rate` inside `set_mode`: rewriting VTS desyncs the
  receiver (FORCE_FE). frame_rate stays a runtime-only control.
- Init defaults: `default_gain=16` (1x), `default_exp_time=4000us` (~52% of the
  8.33 ms frame), `default_framerate=120000000`.
- **CAM0 CSI silence is usually a wiring/port-index bug, not hardware.** On
  J401, CAM0 produced zero CSI bytes forever (`uncorr_err`/timeout) while CAM1
  worked, even with I2C probe/bind succeeding — looked exactly like a dead
  sensor or bad cable. Root cause: the overlay's CAM0 had the right
  `tegra_sinterface` (`serial_a`) but a leftover CSI/VI `port-index` (1) and
  `lane_polarity` (0) that belonged to a different physical routing. Fixed by
  changing only the three CAM0 `port-index` occurrences (endpoint in
  `tegra-capture-vi`, `nvcsi` channel endpoint, and the sensor node's own
  `ports/port@0/endpoint`) to match the carrier's actual factory routing
  (extracted from Seeed's own IMX219 dual-camera overlay), while leaving
  `lane_polarity` at the value that pairing implies. If CAM0 (or any single
  channel) goes silent while the other channel on the same overlay works,
  check `port-index`/`lane_polarity` consistency for that channel's
  `tegra_sinterface` before suspecting the sensor, cable, or carrier hardware.
  This is a different failure signature from `corr_err`/FORCE_FE (see above),
  which is a `pix_clk_hz`/`line_length` math error, not a routing error.
- The same class of bug bit the Orin Nano devkit's CAM1: the stock OV9281
  overlay's `serial_c` `lane_polarity` is `1` where every other stock overlay
  for that same connector says `0`. Same signature — clean I2C probe/bind,
  zero frames, `uncorr_err` timeouts forever. See the `lane_polarity` table
  under "Board variants". The general rule: a routing field that disagrees
  across a board's stock overlays is a bug in the least-tested profile, and
  the sensor-agnostic ones (IMX219/IMX477) are the trustworthy reference.
  Move the camera between the two ports to isolate whether a fault follows
  the camera (hardware) or stays with the DT slot (overlay bug).

---

## Layout of `scripts/ov9281/`

- `build-ov9281-800p-j401.sh` / `build-ov9281-800p-orinnano-devkit.sh` —
  builds the DT overlay + sensor module for the named carrier (see "Board
  variants" above).
- `install-ov9281-800p-j401.sh` / `install-ov9281-800p-orinnano-devkit.sh` —
  installs what the matching build script produced, with backups + rollback
  and a DEFAULT-boot-entry-only extlinux edit (see Step 3).
- `tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit.dts` /
  `tegra234-p3767-camera-p3768-ov9281-dual-orinnano-devkit-800p10bit.dts` —
  committed overlay sources, one per carrier (self-contained; recompile with
  `dtc -@`).
- `ov9281_mode_tbls_800p.h` — the 1280x800@120fps sensor register table
  (ported from the mainline/RPi ov9281 driver); shared by both carriers.
- `controls.patch`, `fix-gain-exposure.patch` — control fixes applied at
  build; shared by both carriers.
- `measure-margin.py` — dual-capture benchmark + live view.
- `set-max-perf.sh` / `restore-max-perf.sh` — lock clocks to max for a
  worst-case margin baseline (fan stays adaptive under `nvfancontrol`).
- `build-j401-720p120.sh` / `build-j401-*` (imx219, routing) — earlier/other
  J401 experiments, kept for reference. Use the board-specific 800p scripts
  above for the current config.
- `docs/ov9281/` — detailed bring-up / controls / 120fps notes.

See `docs/ov9281/OV9281_120FPS_NOTES.md` and `OV9281_HANDOVER.md` (two levels up
in the repo) for the full bring-up and register details.
