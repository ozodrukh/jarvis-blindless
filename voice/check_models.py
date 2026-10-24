"""Real local inference checks using prerecorded speech; never opens a mic."""
import argparse
import json
from pathlib import Path
import subprocess
import time

from worker import VoiceWorker, emit
from logic import parse_decision, heard_wake

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", type=Path, required=True)
args = parser.parse_args()
runtime = args.runtime.resolve()
worker = VoiceWorker(runtime)
context = {"books": [{"id": "demo", "title": "Проверка Джарвиса"}], "last_book_id": "demo", "pending_restart": None}
cases = [
    ("Приветствие", "Привет, ответь коротко", None, "chat"),
    ("Продолжить", "Джарвис, продолжи последнюю книгу", None, "resume"),
    ("Начать сначала", "Включи Проверку Джарвиса с самого начала", None, "restart"),
    ("Свободный разговор", "Расскажи в двух предложениях, почему осенью желтеют листья", None, "chat"),
    ("Аудио: список книг", None, runtime / "check-audio/list.aiff", "list_books"),
    ("Аудио: разговор", None, runtime / "check-audio/chat.aiff", "chat"),
    ("Подтверждение", "Да", None, "confirm"),
]
results = []
for name, text, audio, expected in cases:
    context["pending_restart"] = "demo" if name == "Подтверждение" else None
    worker.history = [{"role": "user", "content": "Начни книгу сначала"},
                      {"role": "assistant", "content": "Начать «Проверка Джарвиса» сначала? Скажи да или отмена."}] if name == "Подтверждение" else []
    started = time.monotonic()
    chunks = list(worker.respond(text, str(audio) if audio else None, context))
    raw = "".join(chunk.text for chunk in chunks)
    try:
        decision = parse_decision(raw, context)
        passed = decision["action"] == expected
        if name == "Аудио: разговор":
            passed = passed and len(decision["reply"]) > 60 and "каталог" not in decision["reply"].lower() and "перечислю" not in decision["reply"].lower()
    except ValueError as error:
        decision = {"error": str(error)}; passed = False
    item = {"case": name, "passed": passed, "seconds": round(time.monotonic() - started, 2), "decision": decision, "raw": raw}
    results.append(item); emit("check", **item)

audio, sample_rate = worker.sf.read(runtime / "check-audio/list.aiff", dtype="float32")
from scipy.signal import resample_poly
import math
divisor = math.gcd(sample_rate, 16000)
audio = resample_poly(audio, 16000 // divisor, sample_rate // divisor)
segments, _ = worker.wake_model.transcribe(audio, language="ru", beam_size=1, initial_prompt="Джарвис.", condition_on_previous_text=False)
heard = " ".join(segment.text for segment in segments)
results.append({"case": "Имя на записи", "passed": heard_wake(heard), "heard": heard})
worker.closed = True
import mlx.core as mx
report = {"device": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
          "memory_gb": round(int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)) / 2**30),
          "peak_mlx_gb": round(mx.get_peak_memory() / 1e9, 2), "results": results}
(runtime / "check-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
emit("summary", passed=sum(x["passed"] for x in results), total=len(results), device=report["device"])
raise SystemExit(0 if all(x["passed"] for x in results) else 1)
