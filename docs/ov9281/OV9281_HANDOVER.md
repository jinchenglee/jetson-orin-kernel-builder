# J401 OV9281 handover

Updated 2026-09-09. 120fps now WORKS at 1280x800 on both cameras - see OV9281_120FPS_NOTES.md (the 720p high-speed build in this file is the superseded attempt).

## Hardware and routing

- Board: Seeed Studio reComputer J4012 carrier, Orin NX 16GB.
- CAM0 is the J401 CSI0 path and is routed as `serial_a`, port-index 0.
- CAM1 is the J401 CSI2 path and is routed as `serial_c`, port-index 2.
- Sensors are at I²C addresses `9-0060` and `10-0060`.
- The J401 routing was derived from Seeed's JP6.1 MFI/device-tree files and is known to enumerate both sensors.

## Current installed state

The active boot overlay is:

```text
/boot/tegra234-p3767-camera-p3768-ov9281-dual-j401-720p10bit.dtbo
```

The active module is:

```text
/lib/modules/5.15.148-tegra/updates/drivers/media/i2c/nv_ov9281.ko
```

The module was built from the local Jetson source tree under `/home/nvidia/l4t/r36.4.7` and matches the running `5.15.148-tegra` kernel. The installer made backups named:

```text
/lib/modules/5.15.148-tegra/updates/drivers/media/i2c/nv_ov9281.ko.pre-720p10
/boot/extlinux/extlinux.conf.pre-720p10
```

Both `/dev/video0` and `/dev/video1` enumerate as 1280×720 `Y10 ` devices with 60 and 120 fps intervals. The custom driver exposes a `frame_rate` control from 60,000,000 to 120,000,000 (micro-fps).

## What works and what does not

Dual OV9281 routing and sensor probing work. Register readback after the high-speed mode is applied shows both sensors configured with:

```text
0x3662 = 0x05
0x380c/0x380d = 0x02d8
0x380e/0x380f = 0x038e
0x4509 = 0x00
```

The high-speed stream does not yet work. Attempts at both 60 fps and 120 fps produce zero-byte files and kernel messages such as:

```text
tegra-camrtc-capture-vi: corr_err: discarding frame
tegra-camrtc-capture-vi: uncorr_err: request timed out
```

Therefore no valid image was produced from the high-speed build. Argus remains unavailable for OV9281 because the Jetson Argus path rejects the monochrome `grey_y10` format (`Unknown sensor pixel type`). V4L2 is the correct test path.

## Repository entry points

- `scripts/ov9281/build-j401-routing.sh`: builds the known J401 routing overlay.
- `scripts/ov9281/install-j401-routing.sh`: installs that routing overlay.
- `scripts/ov9281/build-j401-720p120.sh 10`: builds the current 10-bit high-speed experiment.
- `scripts/ov9281/build-j401-720p120.sh 8`: builds the 8-bit variant.
- `scripts/ov9281/install-j401-720p120.sh 10|8`: installs one depth variant and updates `extlinux.conf`.
- `scripts/ov9281/controls.patch`: experimental frame-rate/exposure control changes.
- `docs/ov9281/controls-experiment.md`: register and datasheet analysis.

Build artifacts are placed under `/tmp/ov9281-j401-720p8-build` and `/tmp/ov9281-j401-720p10-build`. Rebuild them if `/tmp` has been cleaned.

## Safe next steps

1. Restore the previously working 60-fps overlay/module if a known-good capture is needed. Use the `.pre-720p10` module and the earlier `/boot/extlinux/extlinux.conf` backup only after checking their timestamps and contents.
2. Compare the complete sensor register readback during a known-good 60-fps stream with the high-speed sequence. Focus on MIPI output/data-type registers, PLL fields, crop/readout registers, and CSI settle timing.
3. Test one camera only before re-enabling the dual overlay. A one-camera experiment makes CSI errors easier to attribute.
4. Keep the high-speed module and DTBO as a matched pair. Do not combine the 8-bit driver/DTBO with the 10-bit pair.

## Useful commands

```bash
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --list-formats-ext
v4l2-ctl -d /dev/video0 --list-ctrls
sudo udevadm trigger --subsystem-match=video4linux
sudo udevadm settle
journalctl -k -b --no-pager | grep -Ei 'ov9281|corr_err|uncorr_err|nvcsi|capture-vi'
```

For raw 10-bit capture, use the exact four-character format including its trailing space:

```bash
timeout 10 v4l2-ctl -d /dev/video0 \
  --set-fmt-video='width=1280,height=720,pixelformat=Y10 ' \
  --set-ctrl=frame_rate=120000000 \
  --stream-mmap --stream-count=30 --stream-to=/tmp/ov9281.y10
```
