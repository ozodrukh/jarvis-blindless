#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
trap 'printf "\nПодготовка не завершена. Ошибка показана выше. Нажмите Enter, чтобы закрыть окно.\n"; read -r' ERR
printf 'Подготовка Джарвиса. Этот шаг выполняется один раз с интернетом.\nБудут скачаны модели (около 5,3 ГБ) и среда запуска. Оставьте свободными 12 ГБ.\n\n'
export UV_PYTHON_INSTALL_DIR="$PWD/.runtime/python"
export UV_CACHE_DIR="$PWD/.runtime/cache"
export HF_HOME="$PWD/.runtime/hf"
export HF_HUB_DISABLE_TELEMETRY=1
mkdir -p .runtime
if [ ! -x .runtime/venv/bin/python ]; then
  ./tools/uv venv --python 3.12 --python-preference only-managed .runtime/venv
fi
./tools/uv pip sync --python .runtime/venv/bin/python requirements.lock
if [ ! -f .runtime/models/assets.json ]; then
  .runtime/venv/bin/python 'Джарвис.app/Contents/Resources/voice/setup_models.py' --runtime .runtime
fi
printf '\nПроверяю запуск Gemma на этом Mac…\n'
if ! .runtime/venv/bin/python 'Джарвис.app/Contents/Resources/voice/worker.py' --runtime .runtime --check 'Ответь коротко: ты готов?' > .runtime/setup-check.log 2>&1; then
  printf 'Не удалось запустить модель. Подробности: .runtime/setup-check.log\n'
  exit 1
fi
printf '\nГотово. Можно отключить интернет и открыть Джарвис.app.\nВ первый раз разрешите микрофон и выберите папку audiobooks из этого комплекта.\nНе перемещайте приложение отдельно от этой папки: рядом находится его среда запуска.\n\nНажмите Enter, чтобы закрыть окно.\n'
read -r
