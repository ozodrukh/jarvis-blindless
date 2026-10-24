# Jarvis implementation checkpoints

- [x] Config validation and persisted file selection. Acceptance: strict JSON settings and private credential references; invalid selection does not replace saved path. Verify: Python configuration tests, Swift selection tests. Files: configuration.py, test_configuration.py, ConfigurationSelection.swift, ConfigurationSelectionTests.swift, example JSON.
- [x] Online provider adapters and routing. Acceptance: separate STT/LLM/TTS, bounded retry/fallback/cancellation, sanitized responses. Verify: loopback HTTP tests. Files: providers.py, test_providers.py.
- [x] Quiet speech capture and end commands. Acceptance: independent timeouts, local exact end phrases, normalized quiet speech and VAD. Verify: audio regression tests, prerecorded wake/request checks. Files: logic.py, worker.py, test_audio_input.py.
- [x] Worker pipeline. Acceptance: selectable stages and actual fallback metrics, online STT unavailable still allows local exit, stale jobs discarded. Verify: worker tests with fake local models, real local smoke test. Files: worker.py, test_worker.py, check_stream.py.
- [x] Native controls and playback. Acceptance: choose/reload remembered config, end chat control, level/timing display, cancellable remote audio with local speech fallback, saved positions unchanged. Verify: Swift tests/build. Files: App.swift, Controller.swift, VoiceBridge.swift, Player.swift, relevant Swift tests.
- [x] Distribution and documentation. Acceptance: all new worker files/example included in signed app/archive; setup and limits documented. Verify: full Python/Swift suites, release build, package signature/archive contents. Files: scripts/build.sh, scripts/package.sh, Info.plist, README.md, verification docs.

External validation remains: live microphone/speakers, VoiceOver/visual UI, and the user's actual paid model/voice choices. These are not claimed as passed. See docs/verification.md.

---

## MIC: восстановление системного микрофона

Спецификация, план и задачи утверждены 2026-10-24; пользователь поручил реализацию. Старые выполненные пункты выше относятся к предыдущему объёму. MIC-1–3 реализованы; 49 Python- и 31 Swift-тест проходят. Пользователь подтвердил первый живой запуск: работают обе шкалы. Полный набор циклов MIC-4 и второй режим обработки ещё не проверены.

- [x] **MIC-1: Освобождение отдельного сеанса захвата**
  - Приёмка: stop и ошибка на любой стадии освобождают только принадлежащие сеансу ресурсы; повторный stop безопасен; новый запуск не использует старый движок. Ошибка voice processing видна, резервный обычный захват проходит полную инициализацию.
  - Проверка: сначала падающие XCTest для повторного запуска, частичного отказа до/после tap, отказа start и обработки голоса; затем прохождение целевой команды ниже. Проверить освобождение владельцев, а не только вызов stop.
  - Файлы: `Sources/Jarvis/VoiceBridge.swift`, при необходимости небольшой `Sources/Jarvis/MicrophoneCapture.swift`, `Tests/JarvisAppTests/MicrophoneTests.swift`.
  - Зависимости: нет. Размер: 2–3 файла.

- [x] **MIC-2: Восстановление маршрута с отменой устаревших событий**
  - Приёмка: не более одного активного сеанса; остановка отменяет отложенный запуск и поздний ответ на разрешение; callbacks/PCM прежнего сеанса не попадают в действующий. Восстановление ограничено тремя попытками в общем окне пяти секунд, затем ресурсы освобождаются и показана ошибка.
  - Проверка: XCTest со сменой маршрута, серией уведомлений, stop во время восстановления/разрешения, устаревшим PCM и перезапуском голоса; управляемое время вместо реальных задержек. Целевые тесты и сборка.
  - Файлы: `Sources/Jarvis/VoiceBridge.swift`, `Sources/Jarvis/MicrophoneCapture.swift` (если выделен), `Sources/Jarvis/Controller.swift` (если требуется), `Tests/JarvisAppTests/MicrophoneTests.swift`.
  - Зависимости: MIC-1. Размер: до 4 файлов.

- [x] **Контрольная точка A: жизненный цикл**
  - Целевые тесты проходят, release-сборка собирается; рассмотрены частичная инициализация, владение и переходы между очередями.
  - Изменения соответствуют спецификации; новый механизм аудиозахвата или расширение поддерживаемых устройств не внедрены без согласования.

- [x] **MIC-3: Достоверная готовность и ограниченная диагностика**
  - Приёмка: готовность требует успешного старта и первого пригодного PCM-буфера; отсутствие буферов приводит к ограниченному восстановлению/ошибке, а тихие буферы — нет. Старый уровень сбрасывается при остановке. Диагностика содержит только режим/формат, события, счётчики и времена.
  - Проверка: XCTest «буферов нет», «буферы тихие», «первый буфер пришёл поздно от старого сеанса», «поток прекратился», исчерпание попыток и корректное состояние интерфейса; целевые Swift-тесты и Python-регрессия PCM.
  - Файлы: `Sources/Jarvis/VoiceBridge.swift`, `Sources/Jarvis/MicrophoneCapture.swift` (если выделен), `Sources/Jarvis/Controller.swift`, `Tests/JarvisAppTests/MicrophoneTests.swift`, `Tests/JarvisAppTests/ConversationTests.swift` (если требуется).
  - Зависимости: контрольная точка A. Размер: до 5 файлов.

- [ ] **MIC-4: Аппаратное сравнение и проверка комплекта**
  - Подтверждено пользователем 2026-10-24: после запуска новой сборки с прежним конфигом обе шкалы работают при речи. Полные циклы и оба режима пока открыты.
  - Приёмка: оба режима обработки проверены по циклам из спецификации; системная шкала и другое приложение продолжают получать звук; не требуется перезапуск системы/аудиослужбы. Поведение после восстановления проверено обращением и запросом. Если проверка недоступна или сбой не воспроизведён, это явно записано и задача остаётся незавершённой.
  - Проверка: `bash scripts/test.sh`, `bash scripts/build.sh`, `codesign --verify --deep --strict 'dist/Джарвис.app'`; ручной сценарий из `SPEC-audio-input.md`. После успешной аппаратной проверки — `bash scripts/package.sh` и проверка обновлённого архива без личных JSON/ключей.
  - Файлы: `docs/verification.md`, `docs/testing-with-friend.md` (если нужно уточнение сценария); генерируемые приложение/архив в `dist/`. Личный `dist/jarvis-config.json` не изменять.
  - Зависимости: MIC-3. Размер: до 2 исходных документов плюс результаты сборки.

- [ ] **Контрольная точка B: подтверждённое исправление**
  - Автоматические тесты, сборка, подпись и просмотр изменений завершены; аппаратные результаты записаны отдельно от результатов тестов.
  - Все аппаратные критерии дополнения подтверждены; оставшиеся ограничения прямо сообщены пользователю. При непроверенном микрофоне эта точка остаётся открытой.

### Целевые команды MIC-1–3

Выполнять из корня проекта:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox --build-system native --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --filter JarvisAppTests
python3 -m unittest discover -s voice -p 'test_audio_input.py'
bash scripts/build.sh
```


## TTS: форматы озвучки (согласовано 2026-10-24)

- [x] TTS-1: конфигурация формата и корректный raw PCM.
  - Acceptance: старые настройки сохраняют MP3; новые поля валидируются; PCM превращается в WAV с корректными параметрами.
  - Verify: python3 -m unittest discover -s voice -p 'test_configuration.py'; python3 -m unittest discover -s voice -p 'test_providers.py'.
  - Files: voice/configuration.py, voice/providers.py, voice/test_configuration.py, voice/test_providers.py.
  - Dependencies: нет.
- [x] TTS-2: совместимые контейнеры, Ogg/Opus, ограничения и отмена.
  - Acceptance: шесть форматов передаются сервису; Opus декодируется; повреждения и размеры дают резерв; отменённый результат не произносится.
  - Verify: .runtime/venv/bin/python -m unittest discover -s voice -p 'test_providers.py'; python3 -m unittest discover -s voice -p 'test_worker.py'.
  - Files: voice/providers.py, voice/test_providers.py, voice/test_worker.py, voice/test_tts_audio.py, tests/fixtures/tts/.
  - Dependencies: TTS-1.
- [x] TTS checkpoint A: Python-проверки проходят, формат и отмена не нарушают существующий резерв.
- [x] TTS-3: реальные образцы в нативном плеере.
  - Acceptance: все форматы готовятся к воспроизведению, длительность/частота корректны и сигнал ненулевой.
  - Verify: bash scripts/test.sh; целевые TTS-тесты в штатной Python-среде.
  - Files: Tests/JarvisAppTests/SpeechOutputTests.swift, tests/fixtures/tts/, voice/test_tts_audio.py.
  - Dependencies: TTS-2.
- [x] TTS-4: готовая сборка и инструкция.
  - Acceptance: пример и README описывают форматы; текущая Gemini настроена на PCM без изменения других полей; dist содержит адаптер и проходит проверку подписи.
  - Verify: bash scripts/build.sh; codesign --verify --deep --strict dist/Джарвис.app; короткий запрос Gemini и проверка WAV.
  - Files: README.md, jarvis-config.example.json, dist/jarvis-config.json, docs/verification.md; автоматически созданные файлы dist.
  - Dependencies: TTS-3.
- [x] TTS checkpoint B: сборка, live-проверка и оставшиеся ограничения записаны; задачи завершены только по фактическим результатам.
