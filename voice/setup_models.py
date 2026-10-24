"""One-time asset download. The application itself always runs offline."""
import argparse
import json
from pathlib import Path
from huggingface_hub import snapshot_download

MODELS = {
    "gemma": ("mlx-community/gemma-4-e4b-it-4bit", "475b9088d29754a3379866cf5aeb6b41acd313c2"),
    "wake": ("Systran/faster-whisper-tiny", "d90ca5fe260221311c53c58e660288d3deb8d356"),
}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    args = parser.parse_args()
    for name, (repo, revision) in MODELS.items():
        print(f"Скачиваю {repo}…", flush=True)
        snapshot_download(repo, revision=revision, local_dir=args.runtime / "models" / name)
    (args.runtime / "models" / "assets.json").write_text(json.dumps(MODELS, indent=2), encoding="utf-8")
    print("Модели готовы. Теперь можно отключить интернет.", flush=True)
