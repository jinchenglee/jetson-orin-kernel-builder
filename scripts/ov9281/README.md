# OV9281 dual camera for the Seeed J4012 (Orin NX 16GB)

Guide to go from a **fresh clone** of this repo (branch `ov9281`) to a working
**dual OV9281 1280x800 RAW10 @ 120fps** setup on a Seeed Studio reComputer
J4012, plus the live measurement/view scripts.

The OV9281 support is entirely out-of-tree: the sensor module (`nv_ov9281.ko`)
and a Device Tree overlay (`tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit`)
are built here. The kernel itself is the stock L4T/Orin kernel and is built with
the repo's generic kernel scripts.

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

```bash
cd scripts/ov9281
bash build-ov9281-800p.sh
```

That produces both, in `/tmp/ov9281-800p-prod-build/`:

- `tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit.dtbo`
- `nvidia-oot/drivers/media/i2c/nv_ov9281.ko`

The build applies (in order): the 800p mode table (`ov9281_mode_tbls_800p.h`),
`controls.patch` (control factors / ranges / defaults) and
`fix-gain-exposure.patch` (so gain & exposure set at init AND runtime actually
reach the sensor and persist across streams). `DEFAULT_FRAME_LENGTH` is set to
910 (VTS) for the 120 fps mode.

---

## Step 3 — install and reboot

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

The DT overlay change needs a reboot; the module change can be applied without
one (`sudo /sbin/rmmod nv_ov9281 && sudo /sbin/modprobe nv_ov9281`).

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

Live side-by-side view (needs a display session):

```bash
# within the desktop session (DISPLAY set); else use --live-save-dir for PNGs
python3 measure-margin.py --live
python3 measure-margin.py --live --live-save-dir /tmp/liveout --seconds 5   # headless snapshots
```

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

---

## Layout of `scripts/ov9281/`

- `build-ov9281-800p.sh` — builds the DT overlay + sensor module (use this).
- `tegra234-p3767-camera-p3768-ov9281-dual-j401-800p10bit.dts` — committed
  overlay source (self-contained; recompile with `dtc -@`).
- `ov9281_mode_tbls_800p.h` — the 1280x800@120fps sensor register table
  (ported from the mainline/RPi ov9281 driver).
- `controls.patch`, `fix-gain-exposure.patch` — control fixes applied at build.
- `measure-margin.py` — dual-capture benchmark + live view.
- `set-max-perf.sh` / `restore-max-perf.sh` — lock clocks to max for a
  worst-case margin baseline (fan stays adaptive under `nvfancontrol`).
- `build-j401-720p120.sh` / `build-j401-*` (imx219, routing) — earlier/other
  variants, kept for reference. Use `build-ov9281-800p.sh` for the OV9281 800p
  config.
- `docs/ov9281/` — detailed bring-up / controls / 120fps notes.

See `docs/ov9281/OV9281_120FPS_NOTES.md` and `OV9281_HANDOVER.md` (two levels up
in the repo) for the full bring-up and register details.
