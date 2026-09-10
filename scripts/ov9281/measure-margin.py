#!/usr/bin/env python3
"""
measure-margin.py - Dual OV9281 (1280x800 RAW10 @120fps) capture benchmark.

Runs BOTH cameras at the same time, measures sustainable fps (per-camera and
aggregate) and the system's CPU / GPU / power while doing it, so you can see how
much headroom is left for other algorithms.

It is deliberately a *bare* measurement: v4l2-ctl mmap capture streaming to
/dev/null (one CPU memcpy per frame, which is an upper bound) plus metric
sampling (CPU via /proc/stat, GPU+power via tegrastats). No conversion, display
or algorithm is run, so the numbers are the capture-path cost, not an app's.

Usage:
  python3 measure-margin.py [--seconds 10] [--count N] [--fps 120]
                            [--save-dir DIR] [--grab-prefix PREFIX]
  --seconds S      run for S seconds (default 10)
  --count N        stop after N frames per camera (overrides --seconds)
  --fps F          requested frame rate, default 120
  --save-dir DIR   also write the raw Y10 streams to DIR/cam0.y10, cam1.y10
  --grab-prefix P  save one sample frame from each camera as PREFIX_cam0.png /
                   PREFIX_cam1.png (converted to grayscale 8-bit)

Requires: v4l2-ctl, tegrastats (for GPU/power; needs root). CPU parsing works
without root. Root is needed for tegrastats + for locking clocks beforehand.

NOTE on fairness/margin: run `sudo ./set-max-perf.sh` (and reboot to MAXN) first
so the clocks are at static max; otherwise this is a variable-clock baseline.
"""
import argparse, os, re, subprocess, sys, tempfile, time

W, H, BPP = 1280, 800, 2   # 2 bytes per 10-bit pixel (V4L2_PIX_FMT_Y10)


def parse_cpu():
    """Return (busy, total) jiffies from /proc/stat."""
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("cpu "):
                parts = [int(x) for x in line.split()[1:]]
                idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                busy = sum(parts) - idle
                return busy, idle, sum(parts)
    return 0, 0, 0


def run_stream(dev, out, fps, count):
    cmd = ["v4l2-ctl", "-d", dev,
           "--set-fmt-video=width=%d,height=%d,pixelformat=Y10 " % (W, H),
           "--set-ctrl=frame_rate=%d" % (fps * 1000000),
           "--stream-mmap"]
    if count:
        cmd += ["--stream-count=%d" % count]
    cmd += ["--stream-to=%s" % out]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True)


def fps_from_log(text):
    for m in re.finditer(r"([0-9]+(?:\.[0-9]+)?) fps", text):
        pass
    ms = re.findall(r"([0-9]+(?:\.[0-9]+)?) fps", text)
    return float(ms[-1]) if ms else None


def tegrastats_generator(seconds):
    p = subprocess.Popen(["tegrastats"], stdout=subprocess.PIPE, text=True)
    end = time.time() + seconds
    vals = {"gpu": [], "cpu": [], "pwr": []}
    try:
        for line in iter(p.stdout.readline, ""):
            m = re.search(r"GR3D_FREQ\s+([0-9]+)%", line)
            if m:
                vals["gpu"].append(int(m.group(1)))
            m = re.search(r"CPU \[([^\]]+)\]", line)
            if m:
                cpu = [int(x.split("%")[0]) for x in m.group(1).split(",")]
                vals["cpu"].append(sum(cpu) / len(cpu))
            m = re.search(r"VDD_IN\s+([0-9]+)mW", line)
            if m:
                vals["pwr"].append(int(m.group(1)))
            if time.time() > end:
                break
    finally:
        p.terminate()
    return vals


def parse_gpu(lines):
    vals = {"gpu": [], "cpu": [], "pwr": []}
    for line in lines:
        m = re.search(r"GR3D_FREQ\s+([0-9]+)%", line)
        if m:
            vals["gpu"].append(int(m.group(1)))
        m = re.search(r"CPU \[([^\]]+)\]", line)
        if m:
            cpu = [int(x.split("%")[0]) for x in m.group(1).split(",")]
            if cpu:
                vals["cpu"].append(sum(cpu) / len(cpu))
        m = re.search(r"VDD_IN\s+([0-9]+)mW", line)
        if m:
            vals["pwr"].append(int(m.group(1)))
    return vals


def avg(x):
    return sum(x) / len(x) if x else 0.0


def grab_frame(dev, path):
    """Capture a single 1280x800 Y10 frame and save a grayscale PNG."""
    raw = os.path.join(tempfile.gettempdir(), "grab_%d.y10" % os.getpid())
    devid = "cam0" if "video1" in dev else "cam1"
    subprocess.run(["v4l2-ctl", "-d", dev,
                    "--set-fmt-video=width=%d,height=%d,pixelformat=Y10 " % (W, H),
                    "--set-ctrl=frame_rate=%d" % (120 * 1000000),
                    "--stream-mmap", "--stream-count=1", "--stream-to=%s" % raw],
                   check=False, capture_output=True)
    if not os.path.exists(raw) or os.path.getsize(raw) < W * H * BPP:
        print("  (no frame from %s)" % dev)
        return
    import numpy as np
    import cv2
    a = np.fromfile(raw, dtype=np.uint16).reshape(H, W)   # 10-bit sample in HIGH 10 bits (stored=(v<<6)|(v>>4))
    a8 = (a >> 8).astype(np.uint8)                        # high byte = 10-bit >> 2
    cv2.imwrite(path, a8)
    print("  saved %s (%dx%d gray)" % (path, W, H))


def _autolevel(g8, lo_pct=1, hi_pct=99):
    """Contrast-stretch a grayscale frame (float math, no integer banding) so
    the (dark) correctly-converted 10-bit image is visible."""
    import numpy as np
    lo, hi = np.percentile(g8, (lo_pct, hi_pct))
    rng = max(float(hi) - float(lo), 1.0)
    return np.clip(((g8.astype(np.float32) - lo) * 255.0 / rng),
                   0, 255).astype(np.uint8)


def run_live(cam_devs, fps, save_dir=None, duration=0.0):
    """Live side-by-side preview of both cameras.

    The raw Y10 is captured by the proven v4l2-ctl path into a FIFO (avoids the
    GStreamer/cv2 grey_y10 gaps), converted to 8-bit gray (10-bit LSB -> >>2), and
    shown side by side with cv2.imshow. Press 'q' (or wait duration) to stop.
    """
    import threading, cv2, numpy as np
    frame_size = W * H * 2          # 1280*800*2 bytes per Y10 frame
    latest = {}
    counts = {d: 0 for d in cam_devs}
    lock = threading.Lock()
    errs = []
    live_procs = []
    threads = []

    def reader(idx, dev):
        fifo = os.path.join(tempfile.gettempdir(), "livefifo%d.y10" % idx)
        try:
            if os.path.exists(fifo):
                os.remove(fifo)
            os.mkfifo(fifo)
        except FileExistsError:
            pass
        p = subprocess.Popen(["v4l2-ctl", "-d", dev,
                              "--set-fmt-video=width=%d,height=%d,pixelformat=Y10 " % (W, H),
                              "--set-ctrl=frame_rate=%d" % (fps * 1000000),
                              "--stream-mmap", "--stream-to=%s" % fifo],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        live_procs.append(p)
        import os as _os
        # O_RDWR so the read open doesn't block waiting for a writer; select()-based
        # non-blocking loop below so the thread exits when v4l2-ctl stops (avoids a
        # hang: an O_RDWR fd keeps a write-end open, so plain read() never gets EOF).
        import select as _select
        fd = _os.open(fifo, _os.O_RDWR | _os.O_NONBLOCK)
        saved = 0
        produced = 0
        try:
            buf = b""
            while True:
                r, _, _ = _select.select([fd], [], [], 0.5)
                if fd in r:
                    try:
                        chunk = _os.read(fd, frame_size - len(buf))
                    except BlockingIOError:
                        chunk = b""
                    if not chunk:
                        break
                    buf += chunk
                    while len(buf) >= frame_size:
                        a = np.frombuffer(buf[:frame_size], dtype=np.uint16).reshape(H, W)
                        # 10-bit sample is in the HIGH 10 bits (stored=(v<<6)|(v>>4));
                        # high byte = 10-bit >> 2.
                        g8 = (a >> 8).astype(np.uint8)
                        produced += 1
                        with lock:
                            latest[dev] = g8
                            counts[dev] += 1
                        if save_dir:
                            saved += 1
                            if saved % 30 == 0:
                                label = "cam0" if "/video1" in dev else "cam1"
                                cv2.imwrite(os.path.join(save_dir, "%s_live.png" % label), g8)
                        buf = buf[frame_size:]
                elif p.poll() is not None:
                    # v4l2-ctl stopped (or never started): stop reading.
                    break
        except Exception as e:
            errs.append((dev, str(e)))
        finally:
            _os.close(fd)
            p.terminate()
            if produced == 0:
                try:
                    _, err = p.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    p.kill()
                    _, err = p.communicate()
                errs.append((dev, "captured 0 frames%s" %
                             ("; v4l2-ctl: %s" % (err or "device busy?")
                              if (err or "").strip() else "")))
            try:
                if os.path.exists(fifo):
                    os.remove(fifo)
            except OSError:
                pass

    for idx, dev in enumerate(cam_devs):
        t = threading.Thread(target=reader, args=(idx, dev), daemon=False)
        t.start()
        threads.append(t)

    def _cleanup():
        for p in live_procs:
            try:
                p.terminate()
            except Exception:
                pass
        for t in threads:
            t.join(timeout=3)

    if save_dir:
        os.makedirs(save_dir, exist_ok=True)

    import time
    t0 = time.time()
    win = "OV9281 live view (CAM0 | CAM1) - press q to quit"
    has_disp = bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))
    if not has_disp:
        # No display in this session: fall back to snapshot-only (still "live",
        # refreshed by the reader threads) rather than crashing in imshow.
        print("No display detected - saving live snapshots to %s (Ctrl-C to stop, "
              "or pass --seconds to bound it)." % (save_dir or "(none)"))
        try:
            while (not duration) or (time.time() - t0 < duration):
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass
        with lock:
            print("  frames received: %s" % {d: counts[d] for d in cam_devs})
        if errs:
            for dev, e in errs:
                print("  (reader error %s: %s)" % (dev, e))
        _cleanup()
        return

    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(win, 1280, 400)
    print("Live view running. Press 'q' in the window (or wait) to stop.")
    last_report = time.time()
    last_counts = dict(counts)
    while True:
        with lock:
            f0 = latest.get("/dev/video1")
            f1 = latest.get("/dev/video0")
            c0, c1 = counts["/dev/video1"], counts["/dev/video0"]
        if f0 is not None and f1 is not None:
            # Correctly-converted gray (high byte = 10-bit >> 2) is dark because
            # the exposure uses only part of the 10-bit range, so show a
            # percentile-stretched version (float math, no banding) after a
            # light median blur.
            d0 = cv2.cvtColor(cv2.medianBlur(_autolevel(f0), 3), cv2.COLOR_GRAY2BGR)
            d1 = cv2.cvtColor(cv2.medianBlur(_autolevel(f1), 3), cv2.COLOR_GRAY2BGR)
            cv2.imshow(win, cv2.hconcat([d0, d1]))
        now = time.time()
        if now - last_report > 2:
            print("  frames so far: cam0=%d cam1=%d (%.0f/%.0f fps)" %
                  (c0, c1, (c0 - last_counts["/dev/video1"]) / 2.0,
                   (c1 - last_counts["/dev/video0"]) / 2.0), flush=True)
            last_report = now
            last_counts = dict(counts)
        k = cv2.waitKey(30)
        if k == ord("q") or (duration and time.time() - t0 > duration):
            break
    cv2.destroyAllWindows()
    _cleanup()
    if errs:
        for dev, e in errs:
            print("  (reader error %s: %s)" % (dev, e))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--count", type=int, default=0)
    ap.add_argument("--fps", type=int, default=120)
    ap.add_argument("--save-dir", default=None)
    ap.add_argument("--grab-prefix", default=None)
    ap.add_argument("--gpu", action="store_true",
                    help="also sample GPU/power via tegrastats (adds its own CPU "
                         "overhead to the run; off by default so the fps number "
                         "stays close to the true bare-capture rate)")
    ap.add_argument("--live", action="store_true",
                    help="live side-by-side preview of both cameras (needs a "
                         "display/run within the desktop session)")
    ap.add_argument("--live-save-dir", default=None,
                    help="with --live, also save a snapshot PNG per camera every "
                         "30 frames (handy when there is no display)")
    a = ap.parse_args()

    devs = {"/dev/video1": "CAM0(port0)", "/dev/video0": "CAM1(port2)"}

    if a.live:
        # Live preview takes over; it reads from both cameras via FIFO and shows
        # them side by side (or saves snapshots if no display).
        duration = a.seconds if a.seconds else 0.0
        run_live(list(devs.keys()), a.fps, save_dir=a.live_save_dir, duration=duration)
        return

    # Bound the run: if --count not given, derive it from --seconds so each
    # stream ends naturally within the window (v4l2-ctl streams forever otherwise).
    count = a.count or int(a.seconds * a.fps) or None

    print("== Setting format/fps and starting both streams "
          "(requested %d fps, target %dx%d)..." % (a.fps, W, H))

    procs = {}
    outs = {}
    for dev, label in devs.items():
        # Bare capture streams to /dev/null (no disk I/O) so the fps/CPU measure
        # reflects the capture path, not the disk. Real files only on --save-dir.
        if a.save_dir:
            tmp = os.path.join(tempfile.gettempdir(), "measure_%d.y10" % os.getpid())
            outs[dev] = tmp
        else:
            tmp = "/dev/null"
            outs[dev] = None
        procs[dev] = run_stream(dev, tmp, a.fps, count)

    # Metric sampling. CPU via /proc/stat deltas (cheap, no overhead). If --gpu,
    # run tegrastats in a background thread so it doesn't block/compete with the
    # capture and skew the fps number.
    import threading, queue
    gpu_lines = []
    gpu_evt = threading.Event()

    def _gpu_worker():
        try:
            p = subprocess.Popen(["tegrastats"], stdout=subprocess.PIPE, text=True)
            for line in iter(p.stdout.readline, ""):
                gpu_lines.append(line)
                if gpu_evt.is_set():
                    break
        except Exception:
            pass

    if a.gpu:
        gpu_th = threading.Thread(target=_gpu_worker, daemon=True)
        gpu_th.start()

    t0 = time.time()
    cpu_busy, cpu_idle0, cpu_tot0 = parse_cpu()

    # Wait for both streams to finish their frame count naturally (count frames at
    # 'fps' fps takes ~seconds). Give a generous cap so a slow start doesn't force
    # a premature terminate and skew the window.
    hard_cap = time.monotonic() + a.seconds + 8
    while time.monotonic() < hard_cap and any(p.poll() is None for p in procs.values()):
        time.sleep(0.05)

    # Make sure no stream is left running (belt-and-suspenders after a short run)
    for dev, p in procs.items():
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()

    cpu_busy1, cpu_idle1, cpu_tot1 = parse_cpu()
    elapsed = time.time() - t0

    gpu = {"gpu": [], "cpu": [], "pwr": []}
    if a.gpu:
        gpu_evt.set()
        gpu_th.join(timeout=3)
        gpu = parse_gpu(gpu_lines)

    # Report
    print("\n=== RESULTS (bare capture, both cameras concurrently) ===")
    tot_fps = 0.0
    for dev, label in devs.items():
        out, err = procs[dev].communicate()
        fps = fps_from_log(out)
        tot_fps += fps if fps else 0.0
        print("  %-18s %s : %s" % (label, dev,
              ("%.2f fps" % fps) if fps else "(no fps reported)"))
        if a.save_dir:
            shutil_dst = os.path.join(a.save_dir, "cam%s.y10" %
                                      ("0" if "video1" in dev else "1"))
            os.makedirs(a.save_dir, exist_ok=True)
            try:
                import shutil
                shutil.copyfile(outs[dev], shutil_dst)
                print("     wrote raw to %s" % shutil_dst)
            except Exception as e:
                print("     (save failed: %s)" % e)
    print("  Aggregate throughput : %.2f fps" % tot_fps)

    # CPU
    dcpu = cpu_tot1 - cpu_tot0
    dbusy = dcpu - (cpu_idle1 - cpu_idle0)
    cpu_pct = 100.0 * dbusy / dcpu if dcpu else 0.0
    print("  CPU busy avg         : %.1f%% of %d cores (~%.2f cores)" %
          (cpu_pct, os.cpu_count(), cpu_pct / 100 * os.cpu_count()))
    print("  GPU (GR3D) avg       : %.0f%%" % avg(gpu["gpu"]))
    print("  Per-core CPU avg     : %.1f%%" % avg(gpu["cpu"]))
    if gpu["pwr"]:
        print("  VDD_IN              : %.0f mW avg (peak ~%d mW)" %
              (avg(gpu["pwr"]), max(gpu["pwr"])))

    if a.grab_prefix:
        print("\n=== grabbing one sample frame per camera ===")
        for dev, label in devs.items():
            suffix = "cam0" if "video1" in dev else "cam1"
            grab_frame(dev, "%s_%s.png" % (a.grab_prefix, suffix))

    print("\nNOTE: run 'sudo ./set-max-perf.sh' first for a worst-case (locked-max) "
          "baseline; CPU figure includes v4l2-ctl's per-frame memcpy (upper bound).")


if __name__ == "__main__":
    main()
