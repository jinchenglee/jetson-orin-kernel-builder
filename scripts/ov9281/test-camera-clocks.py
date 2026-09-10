#!/usr/bin/env python3
"""Temporarily maximize VI/ISP/NVCSI clocks, capture both ports, then restore."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

if os.geteuid() != 0:
    raise SystemExit('Run with sudo; camera debugfs clock controls require root.')
out = Path(tempfile.mkdtemp(prefix='ov9281-clock-test-'))
base = Path('/sys/kernel/debug/bpmp/debug/clk')
saved = {}
try:
    for name in ('vi', 'isp', 'nvcsi'):
        p = base / name
        saved[name] = {key: (p / key).read_text().strip()
                       for key in ('rate', 'mrq_rate_locked', 'max_rate')}
    (out / 'original-clocks.json').write_text(json.dumps(saved, indent=2))
    print('Original clocks:', json.dumps(saved), flush=True)
    for name, state in saved.items():
        p = base / name
        (p / 'mrq_rate_locked').write_text('1')
        (p / 'rate').write_text(state['max_rate'])
        print(name, 'test rate', (p / 'rate').read_text().strip(), flush=True)
    for device, port in (('/dev/video0', 'cam1'), ('/dev/video1', 'cam0')):
        result = subprocess.run(['timeout', '-s', 'INT', '-k', '3', '12',
            'v4l2-ctl', '-d', device, '--stream-mmap', '--stream-count=90',
            '--stream-to=' + str(out / (port + '.raw'))],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (out / (port + '.log')).write_text(result.stdout)
        print(port, 'exit', result.returncode, result.stdout, flush=True)
        print(port, 'bytes', (out / (port + '.raw')).stat().st_size, flush=True)
finally:
    for name, state in saved.items():
        p = base / name
        try:
            (p / 'rate').write_text(state['rate'])
        finally:
            (p / 'mrq_rate_locked').write_text(state['mrq_rate_locked'])
    print('Original clocks restored. Results:', out, flush=True)
