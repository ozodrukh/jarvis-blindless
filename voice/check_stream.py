"""Exercise the same streaming PCM / wake / inference path as the native app."""
import argparse
import json
import math
from pathlib import Path
import queue
import time
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
import worker as module

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", type=Path, required=True)
parser.add_argument('--gain', type=float, default=1, help='Scale the prerecorded speech, e.g. 0.03 for a quiet-input check')
args = parser.parse_args()
runtime = args.runtime.resolve()
events = queue.Queue()
original_emit = module.emit
def collect(kind, **fields):
    original_emit(kind, **fields)
    events.put({"type": kind, **fields})
module.emit = collect
voice = module.VoiceWorker(runtime)
voice.context = {"books": [{"id": "demo", "title": "Проверка Джарвиса"}], "last_book_id": "demo"}
samples, rate = sf.read(runtime / "check-audio/list.aiff", dtype="float32")
divisor = math.gcd(rate, 16000)
samples = resample_poly(samples, 16000 // divisor, rate // divisor)
samples *= args.gain
pcm = (np.clip(samples, -1, 1) * 32767).astype(np.int16).tobytes() + bytes(32000 * 3)
for index in range(0, len(pcm), 3200):
    voice.pcm(pcm[index:index + 3200])
    time.sleep(.1)
seen = []
deadline = time.monotonic() + 30
passed = False
while time.monotonic() < deadline:
    event = events.get(timeout=max(.1, deadline - time.monotonic()))
    seen.append(event)
    if event["type"] == "decision":
        passed = event["decision"]["action"] == "list_books"
        break
    if event["type"] == "error":
        break
voice.closed = True
report = {"passed": passed, "gain": args.gain, "events": seen}
name = 'stream-check.json' if args.gain == 1 else 'stream-check-quiet.json'
(runtime / name).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
module.emit("stream_summary", passed=passed)
raise SystemExit(0 if passed else 1)
