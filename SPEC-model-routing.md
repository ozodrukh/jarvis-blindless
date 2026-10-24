# Spec: model-routing

Approved scope: CAPABILITY-MAP.md; user authorized implementation on 2026-10-24.

## Objective and success criteria

Route independently configured recognition, reasoning, and synthesis through online services, with existing local fallbacks. An explicitly offline stage never sends a network request. Online requests attempt the service on each turn; transient errors retry with backoff within one total stage deadline, then fall back. Credentials/auth/model errors skip retries. Cancellation exits promptly and never falls back or emits an obsolete result.

Use OpenAI-compatible `/chat/completions` for LLM and `/audio/speech` for TTS. STT supports OpenRouter base64 JSON and standard OpenAI multipart `/audio/transcriptions`, selected by `api_format`. Validate response shape, size, content type, and model decisions before execution. TTS synthesis returns bounded audio bytes; playback remains native. Existing Whisper supports standalone local STT; Gemma supports text and existing direct-audio offline behavior. Unsupported local model selections fail validation.

Defaults: per-attempt timeout 8 seconds, total stage budget 18 seconds, one retry, initial backoff 0.5 seconds. All are configurable within documented ranges. Retry network errors, 408, 429, and 5xx; honor Retry-After within the budget. Never retry action execution. A synthesis failure reuses the completed reply and falls back to macOS speech. Expose stage/provider/model/fallback/elapsed metrics without text or credentials.

## Tech stack, structure, and code style

Python 3.12 standard-library HTTP and existing local runtime. `voice/providers.py` owns HTTP, budgets, and remote adapters; worker owns local-model calls. Example: `route(stage, remote, local, cancelled)`; cancellation raises a distinct exception and is not an ordinary provider failure.

## Commands and testing

`python3 -m unittest discover -s voice -p 'test_providers.py'`

Use a loopback HTTP fixture and local-call fakes: success, offline zero requests, 401 no retry, 503 retry, rate limits, timeout, cancellation, malformed responses, redirect rejection, and response limits. Real paid provider checks require the user's private config and are not necessary to exercise failure behavior.

## Boundaries

Always use TLS remotely, cap all input/output and waits, and redact errors. Never follow redirects with credentials, expose response bodies in logs, or retry completed actions. Ask first before adding provider SDKs or new local engines. Depends only on app-config.

## Open questions

The user's actual model/voice choices remain in their private config; no default paid service is contacted without it.

## Дополнение: формат выхода TTS

Статус: согласовано пользователем 2026-10-24; пользователь явно поручил реализацию. Дополнение относится к существующему модулю `model-routing`; контракт конфигурации согласуется с `SPEC-app-config.md`. Ранее согласованная функциональность сохраняется. План и выполнение записываются в `tasks/plan.md` и `tasks/todo.md`, раздел TTS.

### Цель и подтверждённая проблема

Пользователь выбирает формат ответа онлайн-озвучки в JSON и получает воспроизводимый звук. Сейчас `RemoteClient.synthesize` всегда отправляет `response_format: "mp3"`. Реальный запрос с выбранной моделью `google/gemini-3.8-flash-lite-tts` и голосом `Gero` получил HTTP 400 с требованием PCM; тот же короткий запрос с PCM получил HTTP 200, `audio/pcm;rate=24000;channels=1` и 71040 байт за 1,96 секунды. Голос менять не требуется.

### Контракт конфигурации

Версия JSON остаётся `1`. В `tts` добавляются поля:

| Поле | Значения | По умолчанию | Назначение |
|---|---|---|---|
| `response_format` | `mp3`, `pcm`, `opus`, `wav`, `flac`, `aac` | `mp3` | Формат, который приложение запрашивает у сервиса |
| `pcm_sample_rate_hz` | Целое число 8000–96000 | `24000` | Частота raw PCM, если она не указана в ответе |
| `pcm_channels` | `1` или `2` | `1` | Каналы raw PCM, если они не указаны в ответе |

Формат задаётся явно, независимо от имени модели и сервиса. Автоматическое переключение формата и повторный платный синтез с другим форматом не входят в задачу. Старый JSON без новых полей продолжает запрашивать MP3. В offline-режиме поля не меняют локальную озвучку. Неизвестный формат, неверный тип, `null`, булево значение вместо числа и выход за диапазон отклоняются до обращения к сети.

Пример раздела для уже проверенной комбинации, без секретов:

```json
"tts": {
  "mode": "online",
  "model": "google/gemini-3.8-flash-lite-tts",
  "base_url": "https://openrouter.ai/api/v1",
  "api_key_env": "OPENROUTER_API_KEY",
  "voice": "Gero",
  "response_format": "pcm",
  "pcm_sample_rate_hz": 24000,
  "pcm_channels": 1,
  "language": "ru-RU"
}
```

Поля `pcm_*` описывают локальную интерпретацию ответа и не добавляются в запрос сервиса. Поддерживаемый raw PCM в этой версии — signed 16-bit little-endian, interleaved. Другие разрядности, float PCM и big-endian не поддерживаются; известное несовпадение отклоняется. Параметры raw PCM не применяются к WAV и другим контейнерам, у которых есть собственные метаданные.

### Получение и воспроизведение

- В `/audio/speech` передаётся выбранный `tts.response_format` без подмены. Сервис отвечает за доступность выбранного формата у конкретной модели.
- Принимаются допустимые аудио MIME и `application/octet-stream`. JSON/HTML с HTTP 200 не считаются аудио. Проверяется совместимость типа ответа и фактического контейнера с выбранным форматом, с учётом допустимых MIME-алиасов.
- Raw PCM получает WAV-заголовок для существующего нативного плеера. Корректные `rate` и `channels` из `Content-Type` имеют приоритет над настройками; отсутствующие значения берутся из `pcm_*`. Неверные, конфликтующие или выходящие за диапазон метаданные отклоняются. Длина данных должна соответствовать целому числу PCM-фреймов.
- Для `opus` гарантируется Ogg/Opus; WebM/Opus в этот контракт не входит. Декодирование в WAV выполняется имеющейся `soundfile`, если нативный путь не обеспечивает воспроизведение на минимальной macOS. Установленная среда содержит `soundfile 0.13.1`, libsndfile 1.2.2 и поддержку `OGG/OPUS`; это предварительная проверка возможностей, а не доказательство воспроизведения.
- MP3, WAV, FLAC и AAC должны проходить проверку настоящими образцами на macOS 14+. Для AAC контракт ограничен ADTS AAC; M4A не считается синонимом `aac`. Нативное воспроизведение или преобразование существующими библиотеками должно быть подтверждено до объявления формата поддержанным. Если это требует новой зависимости, сначала пересматривается спецификация.
- Python возвращает в существующее событие `speech` пригодные для плеера байты. Swift не должен угадывать параметры raw PCM. Публичный мост не получает ключи, личный JSON или тело ошибки провайдера.
- Действующий лимит 16000000 байт применяется и к загружаемому ответу, и к готовому аудио с заголовком. Размер декодированного результата ограничивается до полной распаковки. Превышение лимита, пустые/повреждённые данные и ошибки декодера дают безопасную ошибку этапа.
- Сетевые таймауты и правила повторов сохраняются. Проверки отмены выполняются до и после преобразования; устаревший результат не произносится. Преобразование ограничено размером данных и не блокирует обработку команды отмены.
- Отказ модели поддержать формат, неверное аудио или невозможность воспроизведения переводят готовый ответ на существующую озвучку macOS. LLM и действия плеера повторно не выполняются. В существующих метриках сохраняются резерв и безопасная причина ошибки без сырого ответа сервиса.

Это выбор формата запроса и его воспроизведение, без потоковой передачи, сохранения озвучки в файлы, смены модели или автоматического обнаружения возможностей провайдера.

### Технологии, структура и стиль

Сохраняются Swift tools 5.9, macOS 14+, Python 3.12, стандартная библиотека Python и уже закреплённая `soundfile 0.13.1`. Установка Homebrew/FFmpeg на пользовательском Mac не требуется.

| Путь | Ответственность в рамках дополнения |
|---|---|
| `voice/configuration.py` | Значения по умолчанию и проверка новых полей |
| `voice/providers.py` | Формат запроса, метаданные ответа, подготовка ограниченного аудио |
| `voice/worker.py` | Существующие отмена, резерв и событие с готовым аудио |
| `Sources/Jarvis/VoiceBridge.swift` | Проверка совместимости с существующим нативным воспроизведением |
| `voice/test_configuration.py`, `voice/test_providers.py`, `voice/test_worker.py` | Проверки контракта, ошибок и отмены |
| `Tests/JarvisAppTests/` | Проверки подготовки воспроизведения настоящих аудиообразцов |
| `jarvis-config.example.json`, `README.md` | Описание форматов и пример PCM для Gemini |
| `dist/Джарвис.app`, `dist/jarvis-config.example.json` | Результат штатной сборки после проверки |

Следовать текущим небольшим функциям, отступам в четыре пробела и `snake_case` в Python; существующим Swift-конвенциям. Пример стиля проверки из проекта:

```python
if config['stt']['api_format'] not in ('openrouter', 'openai'):
    _fail('stt.api_format')
```

Новые ошибки используют существующий `ProviderError` и безопасные коды. Форматирование всего файла и общие рефакторинги не входят в изменение.

### Команды и стратегия проверки

Из корня проекта:

```sh
python3 -m unittest discover -s voice -p 'test_configuration.py'
python3 -m unittest discover -s voice -p 'test_providers.py'
bash scripts/test.sh
bash scripts/build.sh
```

Использовать `unittest`, loopback HTTP-фикстуру, существующие Swift XCTest и небольшие настоящие аудиообразцы без секретов. Декодирование Opus проверять также в `.runtime/venv/bin/python -m unittest discover -s voice -p 'test_providers.py'`, где установлен штатный декодер. Ошибка отсутствующего декодера должна иметь отдельную проверку. Числовой порог покрытия не вводится; перечисленные ниже случаи обязательны.

### Критерии готовности

1. Все шесть значений формата проходят валидацию и без изменений попадают в тело HTTP-запроса. JSON без поля сохраняет MP3, локальный режим не делает запросов.
2. PCM с параметрами в ответе и без них даёт корректный WAV: частота, каналы, 16-bit данные и длительность совпадают. Стерео, неверные заголовки и неполный фрейм покрыты тестами.
3. Настоящие MP3, Ogg/Opus, WAV, FLAC и ADTS AAC доходят до успешной подготовки нативного воспроизведения; проверяется ненулевой аудиосигнал. Реальная громкость и отсутствие искажения скорости проверяются прослушиванием на Mac.
4. Повреждённое аудио, JSON вместо аудио, несовместимый формат и превышение размеров дают локальный резерв без повторного действия. Отмена и устаревший запрос не включают ни онлайн-, ни локальную озвучку.
5. Пример PCM для Gemini документирован. Повторная проверка короткой фразой с личным конфигом должна подтвердить онлайн-результат и воспроизведение; тесты без сети не требуют оплачиваемого API.
6. Штатные Python/Swift-проверки и сборка проходят. Обновлённое приложение в `dist` содержит новый адаптер; личный `dist/jarvis-config.json` не перезаписывается сборкой.

### Границы

- Всегда: валидировать конфигурацию, ограничивать загрузку и распаковку, сохранять отмену и локальный резерв, проверять реальные контейнеры и редактировать документацию вместе с поведением.
- Сначала согласовать: новую зависимость, обязательный внешний конвертер, изменение минимума macOS или расширение поддерживаемого PCM за пределы signed 16-bit little-endian.
- Никогда: публиковать ключи/ответы с секретами, менять модель/голос автоматически, повторять выполненные действия или перезаписывать личный конфиг без отдельного разрешения.

### Открытые вопросы и источники

Блокирующих вопросов по требованиям нет. Перечень из шести форматов и контракт PCM согласованы пользователем. Реализация и проверки завершены на macOS 27.0; результаты находятся в `docs/verification.md`. Подготовка воспроизведения на минимальной macOS 14 и прослушивание пользователем остаются непроверенными ограничениями.

[Документация OpenRouter TTS](https://openrouter.ai/docs/guides/overview/multimodal/tts), проверена 2026-10-24: в настоящее время описывает MP3/PCM и ограничение Gemini на PCM. Остальные форматы нужны для других совместимых сервисов; наличие поля в приложении не расширяет возможности OpenRouter.
