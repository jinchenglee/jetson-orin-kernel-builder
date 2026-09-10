# J401 OV9281 controls experiment — 2026-09-09

## Hardware and clock result

Reviewed `/home/nvidia/reComputer_J401_SCH_V1.0.pdf`, page 14 visually and
pages 5/14 as extracted text. J12/CAM0 connects CSI0 D0/D1/CLK, J9/CAM1
connects CSI2 D0/D1/CLK. U36 SGM7222 selects CAM0 with S=0 and CAM1 with
S=1. This explicitly resolves the runbook's earlier mux-polarity uncertainty.
Carrier net names alone do not establish the complete Tegra software port and
polarity mapping. Routing is unchanged for this controls experiment.

The operator ran `scripts/ov9281/test-camera-clocks.py` with sudo.
Original VI/ISP/NVCSI rates: 115200000 / 115200000 / 642900000 Hz,
all with mrq_rate_locked=0. Test rates: 832000000 / 1011200000 / 642900000.
CAM1 produced 90 frames, 165888000 bytes, at 30.02 fps. CAM0 produced zero
bytes and timed out. Script restored original rates and lock flags.
Results: `/tmp/ov9281-clock-test-mcm2j2kf`.

## Experimental controls changes

`scripts/ov9281/controls.patch` is relative to the already-patched local
`/home/nvidia/l4t/r36.4.7` BSP, not pristine NVIDIA or FRC sources.

- Register TEGRA_CAMERA_CID_FRAME_RATE and implement VTS writes to 0x380e/f.
- Use scaled fps and exposure units in both mode0 nodes (factor 1000000).
- Limit advertised frame rates to 2–60 fps, default 60.
- Convert exposure microseconds into lines; encode lines << 4 and write all
  three bytes at 0x3500–0x3502, per the local reference ov9282.c.
- Clamp exposure to VTS minus the reference driver's 12-line margin, including
  when shortening frame length. Set a 10000-us initial exposure after mode init.
- Replace the inherited no-op group-hold callback with register 0x3308 writes,
  following the same local reference.
- Set gain_factor=16 so the raw gain range expresses the correct 1x base.

The 160 MHz timing model and minimum VTS=1742 remain provisional: the actual
30-versus-advertised-60 fps discrepancy is unresolved. Do not claim accurate
exposure duration or frame-rate control until measured on hardware. Clearing
Argus's missing-controls error may expose further monochrome/ISP limitations.
These changes do not establish whether CAM0 hardware is faulty.

## Build and validation

Run `bash scripts/ov9281/build-controls.sh`. It stages sources in
`/tmp/ov9281-controls-build`, applies the patch and builds only the sensor module
and DTBO. It does not modify the BSP source tree or installed drivers.

Completed: module build with -Werror, matching kernel vermagic and all imported
symbol CRCs against the installed module, DTBO compilation, successful merge
with the configured base DTB, and verification of both merged control ranges.
DTC reports inherited overlay warnings (including the existing obsolete GPIO
hog node); these were not changed. Runtime tests remain pending installation.

Install with `sudo bash scripts/ov9281/install-controls.sh`, then reboot.
The installer backs up both current files under `/boot/ov9281-before-controls.*`
and writes a restore.sh there. It changes only nv_ov9281.ko and the existing
OV9281 dual DTBO, then runs depmod. It does not edit extlinux.conf or reboot.
Rollback: run the printed restore.sh with sudo and reboot.

After reboot, inspect controls and binding, capture CAM1 using V4L2 first,
compare requested 30/60 fps and exposure levels, and retry Argus sensor IDs
0/1 with bounded headless captures. Check daemon logs for the next blocker.

## Runtime result

Installed and rebooted successfully. Both cameras expose `frame_rate` with the
new 2–60 fps scaled range; the live DT has the revised factors and limits.
The framework initially reports the minimum (2 fps), so tests explicitly set
60,000,000 before capture. CAM1 (`/dev/video0`, bus 9) produced 90 frames,
165,888,000 bytes, at 30.02 fps. Its read-back registers were VTS 0x06ce
(1742 lines) and exposure 0x004150, equal to the requested 10,000 us after
the required four-bit sensor encoding. The hardware therefore accepts the
revised controls, but the unexplained 30 fps delivery rate remains.

CAM0 (`/dev/video1`, bus 10), with identical requested controls, produced
zero bytes and three normal 2500-ms VI timeouts. The control work and the
clock experiment have not changed its failure.

Argus sensor IDs 0 and 1 both now pass the prior V4L2-control validation, but
both fail at the next layer: `Unknown sensor pixel type` in
`translateColorFormat()`. Argus does not accept this `grey_y10` monochrome
sensor format. This failure happens before it opens either CSI stream, so it
cannot be used to diagnose CAM0. Direct V4L2 remains the supported path.

## Upstream review corrections

At FRCJetsonApril commit 4d40356, the 8-bit and 10-bit named patches are
byte-identical and configure 8-bit. CAM0's sensor endpoint is port 0 while
VI/CSI input overlay overrides use port 1; the runbook's claim of copying
that configuration verbatim is too strong. Main capture.cpp uses raw V4L2;
mixed testcommands.sh examples do not establish OV9281 Argus support.
At ov9281kernelmods commit 5b4e4c2, the driver still lacks frame-rate controls
and relies on the module MCU for sensor initialization.

## J401 Seeed-routing control test — 2026-09-09

The extracted Seeed JP6.1 MFI image was inspected at
`/home/nvidia/Downloads/seeed-jp61/mfi_recomputer-orin-j401` without flashing.
It is R36.4.0 with kernel ABI `5.15.148-tegra` and requests a
J401-specific `tegra234-p3767-camera-p3768-imx219-dual-seeed.dtbo`. Decompiling
the corresponding dual-IMX219 overlay showed the exact carrier routing:

```text
CAM0: serial_a, CSI/VI port-index 0, lane_polarity 6
CAM1: serial_c, CSI/VI port-index 2, lane_polarity 0
```

Our earlier J401 IMX219 overlay had changed CAM0 to `serial_a` but left its
CSI/VI port indices at 1 and changed polarity to 0. That was not Seeed's
configuration. `scripts/ov9281/build-j401-imx219.sh` was updated to change
only the three CAM0 port indices and serial interface while preserving
polarity 6. The resulting overlay was installed as
`/boot/tegra234-p3767-camera-p3768-imx219-dual-j401.dtbo`.

After reboot, both IMX219 cameras captured successfully with raw V4L2 at
1640×1232 RG10: each produced 484,915,200 bytes for 30 frames at about 21.19
fps. Both Argus pipelines (`nvarguscamerasrc sensor-id=0` and `sensor-id=1`)
also completed 30 buffers without errors. Demosaiced first frames showed real
scene content from both cameras.

This supersedes the earlier CAM0 hardware-fault hypothesis. The J401 CAM0 CSI
path is functional; the earlier failure was caused by the incomplete routing
overlay. The validated dual-IMX219 setup is now the baseline for adapting the
OV9281 overlay. OV9281 remains proven on CAM1, while its CAM0 node should next
be tested with the same Seeed `serial_a`/port-0 mapping and the sensor-specific
OV9281 initialization already present in the patched driver.

## Dual OV9281 J401 routing validation — 2026-09-09

The active patched OV9281 overlay was rebuilt while preserving its 10-bit mode,
register initialization, and timing. Only the three CAM0 endpoint port indices
were changed from 1 to 0, matching the validated Seeed IMX219 routing. After
reboot:

```text
/dev/video1: ov9281 10-0060 (CAM0, tegra-capture-vi:0)
/dev/video0: ov9281 9-0060  (CAM1, tegra-capture-vi:2)
```

Both devices advertise `Y10 ` (note the trailing space) at 1280×720. Each
produced 55,296,000 bytes for a 30-frame capture, exactly 1280×720×2×30.
Converted frames show real scene imagery from both cameras. This confirms the
dual OV9281 J401 routing and removes the previous CAM0 routing blocker.

The udev trigger used during troubleshooting was only needed to recover missing
device nodes after one boot; it is not expected to be part of normal camera
startup.

Argus remains a separate pending test. Earlier attempts reached Argus's
`Unknown sensor pixel type` error for `grey_y10`; now that both V4L2 paths are
known-good, retry both sensor IDs to distinguish an Argus monochrome-format
limitation from any remaining pipeline issue.

The retry was performed for both sensor IDs. Both pipelines reached the Argus
daemon but returned `No cameras available`. The daemon log identifies the
underlying cause as `Unknown sensor pixel type` while translating `grey_y10`.
Thus CSI routing and V4L2 capture are working; Argus currently rejects this
monochrome format before opening either stream.

The next target is 120 fps. The current sensor table uses HTS=1530, VTS=1742,
and a 160 MHz pixel clock, which is approximately 60 fps. A 120-fps mode will
need sensor timing/register changes (roughly VTS=871), matching driver and DT
frame-rate limits, and CSI bandwidth validation. Raising only the DT-advertised
maximum cannot produce 120 fps.

## OV9281 datasheet 120-fps analysis — 2026-09-09

The vendor datasheets in `/home/nvidia/J4012_ov9281_docs` provide a concrete
120-fps reference. `OV9281_DataSheet.pdf` table 2-1 specifies:

```text
1280×800 full resolution: 120 fps, 2-lane MIPI, 800 Mbps per lane
1280×720 cropped:          130 fps, 2-lane MIPI, 800 Mbps per lane
640×480 cropped:           180 fps
640×400 subsampled:        210 fps
```

The datasheet's table 2-10 is explicitly labelled as the PLL configuration for
1-megapixel, 120-fps, 2-lane, 10-bit output. Its relevant values are the same
PLL values already present in our register table:

```text
0x0302 = 0x32    PLL1 multiplier
0x030D = 0x50    PLL2 multiplier
0x030E = 0x02    PLL2 system divider
0x0312 = 0x07    PLL2 analog divider
0x0313 = 0x01    PLL2 ADC divider
SYS_CLK = 80 MHz
MIPI_PCLK = 100 MHz
MIPI serial clock = 800 Mbps
```

The documented full-resolution timing defaults in table 7-8 are:

```text
0x3808/0x3809 = 0x0500   output width 1280
0x380A/0x380B = 0x0320   output height 800
0x380C/0x380D = 0x02D8   HTS 728
0x380E/0x380F = 0x038E   VTS 910
```

With the documented 80-MHz sensor clock, `80,000,000 / (728×910)` is about
120.7 fps, matching the specified 120-fps mode. This is more authoritative
than the earlier rough VTS=871 estimate, which assumed the current 160-MHz
model and should be discarded.

The datasheet does not provide a complete copy-and-paste mode register table;
it provides register definitions, PLL examples, and reset/default timing. The
safe implementation path is therefore to retain the proven current common and
PLL registers, create a documented 1280×800 mode with the timing values above,
and validate sensor read-back, actual frame rate, and CSI stability on one
camera before enabling both. The current 1280×720 table remains the known-good
60-fps fallback.

### Driver/register review against the datasheet

The current initialization is sufficient for a stable 1280×720 stream, but it
is not yet a clean representation of the OV9281 datasheet:

- The driver calls the only populated table `OV9281_MODE_1280x720_8` and keeps
  `sensor_mode = 5` (the old InnoMaker 720p-8-bit mode), while the live DT
  advertises 10-bit `grey_y10`. The enum, module comment, table name, and DT
  mode should be made consistent before adding more modes.
- The current table writes the PLL values `0x0302=0x32`, `0x030D=0x50`, and
  `0x030E=0x02`; these agree with the datasheet's 120-fps sample PLL. It does
  not explicitly write every PLL field shown in table 2-10, so a production
  mode should write the complete PLL set rather than depend on reset values.
- The current 720p timing (`0x3808/09=1280`, `0x380A/0B=720`, HTS 1530,
  VTS 1742) is a valid conservative mode and explains the measured ~60 fps.
  It is not the datasheet's 120-fps timing.
- The datasheet identifies `0x3022[7:4]` as the MIPI bit-depth selector
  (`0100`=8-bit, `0101`=10-bit). The current table writes `0x3022=0x01`, so
  this must be verified by live I²C readback. The DT's `csi_pixel_bit_depth`
  property alone does not program the sensor. Do not assume the stream is true
  RAW10 until this register is confirmed.
- Exposure is 20-bit across `0x3500`, `0x3501`, and `0x3502`, with a maximum
  of frame length minus 12 rows. The installed experimental module was
  corrected to write all three bytes and clamp against VTS; the older source
  copy still contains the two-byte write and must not be the reference for
  further builds.
- The populated 1280×720 table is copied from the in-tree `ov9282.c` source
  despite the OV9281 ID. It has proven functional, but every register outside
  the documented PLL, timing, and exposure fields should be treated as a
  borrowed mode sequence pending a line-by-line datasheet check.

Before changing the mode, read back `0x3022`, the PLL fields, and timing fields
from both sensors while streaming. This distinguishes a real 10-bit sensor
mode from a V4L2 format description imposed only by the receiver.

### 1280×720 high-speed comparison

The live readback is identical on buses 9 and 10: `0x3022=0x01`, the expected
PLL values, and the current 60-fps HTS/VTS. `0x3022=0x01` should not be changed
blindly: the independent ArduCAM OV9281 driver also leaves it at 0x01 and
selects 10-bit output with `0x3662=0x05`.

That driver provides a concrete 1280×720 high-speed sequence:

```text
0x3803 = 0x28       crop top 40
0x3806/07 = 0x0307  crop bottom
0x3808/09 = 0x0500  output width 1280
0x380A/0B = 0x02D0  output height 720
0x380C/0D = 0x02D8  HTS 728
0x380E/0F = 0x038E  VTS 910
0x3820 = 0x40
0x3821 = 0x00
0x4008 = 0x04
0x4009 = 0x0B
0x400D = 0x07
0x3662 = 0x05       10-bit output selection
```

This agrees with the datasheet's 800-Mbps/lane PLL and timing model and keeps
the requested 1280×720 output. The current table differs substantially: it
uses HTS 1530/VTS 1742, leaves `0x3662` unwritten, and uses different crop and
readout values. The next patch should port this complete 720p sequence into a
separate experimental mode, advertise 120 fps, and validate actual capture on
one camera before applying it to both. The ArduCAM sequence is a reference,
not yet a drop-in guarantee for this Jetson tegracam driver.
## 720p high-speed build prepared

The repository now contains `scripts/ov9281/build-j401-720p120.sh`. It builds matching 8-bit and 10-bit driver/DTBO pairs for both J401 OV9281 links. The mode is 1280x720 with the datasheet/ArduCAM high-speed crop and timing: HTS 728, VTS 910, 80 MHz pixel clock, and 800 Mb/s per MIPI lane. The sensor register selector is `0x3662=0x05` for 10-bit and `0x3662=0x07` for 8-bit; the 8-bit variant also uses `0x030d=0x60`.

The first installed 10-bit build enumerates both cameras and exposes 60/120 fps, but streaming currently produces CSI frame-discard/time-out errors. Review found that its mode table retained `0x4509=0x80`; the reference high-speed sequence uses `0x4509=0x00`. The corrected build was installed and readback confirms `0x4509=0x00` on both sensors, but 60 fps and 120 fps captures still produce zero bytes. The next investigation should compare the sensor's MIPI timing/data-type registers against the known-good 60 fps mode before another installation.

Both variants expose 60 and 120 fps in the V4L2 frame-rate menu. The depth is selected at boot because CSI metadata and sensor initialization must agree; use `scripts/ov9281/install-j401-720p120.sh 8` or `10`, then reboot. The build artifacts are placed in `/tmp/ov9281-j401-720p8-build` and `/tmp/ov9281-j401-720p10-build`. The 10-bit variant was installed and tested; it enumerates both cameras but does not yet produce valid frames.
