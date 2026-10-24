#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/package
codesign --verify --deep --strict dist/Джарвис.app
STAGE="$(mktemp -d "$PWD/.build/package/jarvis.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Джарвис"
ditto dist/Джарвис.app "$STAGE/Джарвис/Джарвис.app"
ditto dist/tools "$STAGE/Джарвис/tools"
ditto dist/audiobooks "$STAGE/Джарвис/audiobooks"
cp 'dist/Настроить Джарвиса.command' dist/requirements.lock dist/jarvis-config.example.json 'dist/ПРОЧИТАЙТЕ.md' 'dist/Проверка с другом.md' "$STAGE/Джарвис/"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Джарвис" dist/Джарвис-прототип.zip
printf 'Комплект для переноса: %s/dist/Джарвис-прототип.zip\n' "$PWD"
