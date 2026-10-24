# Spec: audio-input

Approved scope: CAPABILITY-MAP.md; user authorized implementation on 2026-10-24.

## Objective and success criteria

Improve normal-volume wake and request capture using the Mac's built-in microphone/speakers. Offline wake recognition remains available during network failures. Use existing installed speech-activity detection and normalize quiet audio for recognition, with bounded gain, configurable sensitivity, and a microphone level indication. Never amplify silence into a request. Diagnostics contain levels and timing, not recorded speech.

Separate `conversation.silence_timeout_seconds` (wait for a follow-up) from `audio.end_silence_seconds` (pause ending a single utterance) and maximum utterance duration. Preserve pre-roll so words spoken with the wake word survive. Recognize configured end-chat phrases locally, including while online inference or synthesis is pending. Ordinary replies mentioning a phrase and negated commands are not exact end-chat commands.

Hardware acceptance: on the user's Mac, try 20 wakes and 10 requests at normal speaking volume and a stated desk distance, first with quiet speakers, then during audiobook playback. Record missed wakes, clipped requests, and false activations. Target at least 19/20 wakes and 9/10 intelligible requests in quiet conditions; this remains a physical verification requirement, not an automated-test claim.

## Tech stack, structure, and code style

Existing AVAudioEngine, faster-whisper 1.2.1/Silero VAD, NumPy. Capture and intent helpers live in `voice/logic.py`; device capture stays in `Sources/Jarvis/VoiceBridge.swift`. Example: `Capture(now, silence_timeout=30, end_silence=1.2)`. No model downloads or new engines.

## Commands and testing

`python3 -m unittest discover -s voice -p 'test_audio_input.py'`

`.runtime/venv/bin/python voice/check_stream.py --runtime .runtime --gain 0.03`

Tests cover silence, configurable independent deadlines, quiet spoken fixtures, preserved wake audio, and false end-chat matches. A real-model streamed recording verifies the processing path; live microphone quality requires the hardware trial above.

## Boundaries

Always bound PCM buffers and gain; keep control detection local; expose input level without retaining audio. Ask first before installing another model or changing supported devices. Never claim microphone hardware is faulty without measurement, or count prerecorded checks as a live microphone trial. Depends only on app-config.

## Open questions

Desk distance/noise and real-user accuracy require a hardware trial after the app is built.

---

## Дополнение: восстановление системного микрофона

Статус: **спецификация утверждена пользователем 2026-10-24**. Относится к существующему модулю `audio-input` из `CAPABILITY-MAP.md`. Ранее согласованный объём выше сохраняется. Технический план и задачи также утверждены; пользователь поручил реализацию. Программная часть реализована, аппаратное подтверждение остаётся открытым.

### Цель и исходные данные

Устранить ситуацию, когда активный захват Jarvis сопровождается отсутствием сигнала как в приложении, так и в системной шкале входа macOS. Пользователь подтвердил: после полного завершения Jarvis системная шкала сразу восстанавливается.

Наблюдения диагностики на Mac пользователя, macOS 27.0 (26A428):

- Выбран встроенный микрофон; при проверке hardware mute выключен, входная громкость 1.0, эксклюзивный владелец устройства отсутствует (`hog = -1`).
- В системном журнале Jarvis присутствуют `Failed expectation of constructed aggregate`, `Timeout waiting for streams` и `StartAndWaitForState returned error 35`.
- Журнал фиксирует переключения аудиомаршрута, включая виртуальное устройство Background Music. Само наличие этого драйвера не доказывает, что он вызывает сбой.
- В текущем `dist/jarvis-config.json` задано `voice_processing: false`; в примере — `true`. Нельзя объяснять сбой только включённой обработкой голоса.
- `VoiceBridge` сохраняет один `AVAudioEngine` между остановками и перезапусками, а ошибки изменения voice processing подавляются через `try?`.

Причина на уровне конкретного вызова ещё не доказана. Рабочая гипотеза: после изменения маршрута или обработки повторно используется некорректное состояние движка/его аудиоустройства. Подтверждение требует воспроизведения и сравнения до/после исправления. Не считать пересоздание движка доказанным решением заранее.

### Предположения и требования

1. Основной поддерживаемый сценарий — встроенный микрофон и динамики Mac. Установленный Background Music учитывается как условие воспроизведения; поддержка его входа как отдельного источника не добавляется.
2. Захват Jarvis должен сосуществовать с системной шкалой входа и другим приложением, которому уже разрешён микрофон.
3. Выключение микрофона, перезапуск голосового режима, ошибка запуска и завершение приложения должны освобождать принадлежащие Jarvis ресурсы захвата. Остановка должна быть безопасна и при частично завершённой инициализации.
4. После смены устройства захват возобновляется только после проверки актуального формата. Старые callbacks и отложенные перезапуски не должны возобновлять выключенный микрофон или передавать устаревшие PCM.
5. Сохраняются оба значения `voice_processing`. Ошибка применения режима должна быть различима в диагностике. Резервный обычный захват допустим только после успешной инициализации и с указанием фактического режима.
6. Статус готовности не выдаётся при неудавшемся запуске. Если захват не восстанавливается, приложение освобождает его и показывает понятную ошибку с возможностью повторного запуска; бесконечные перезапуски недопустимы.
7. Нулевой уровень сам по себе не доказывает сбой: тишина не должна запускать автоматическое восстановление. Отсутствие аудиобуферов и тихие буферы различаются в диагностике.

### Технологии и структура

Существующие Swift (SwiftPM, tools version 5.9), AVFoundation/AVAudioEngine и Foundation; минимальная версия macOS остаётся 14. Python-процесс, Whisper и протокол PCM 16 kHz mono int16 сохраняются.

- `Sources/Jarvis/VoiceBridge.swift` — владение захватом, обработка смены маршрута и ошибки.
- `Sources/Jarvis/Controller.swift` — состояние микрофона и сообщения пользователю, если потребуется согласование с жизненным циклом захвата.
- `Tests/JarvisAppTests/` — регрессионные XCTest для запуска, остановки и восстановления.
- `voice/test_audio_input.py` — существующие проверки обработки PCM.
- `docs/verification.md` — фактические результаты воспроизведения и аппаратной проверки с ограничениями.

### Стиль кода

Сохранить существующие имена в camelCase, отступы в четыре пробела и короткие `guard`. Пример существующего интерфейса:

```swift
func startMicrophone() {
    if microphoneRunning { return }
    guard let session = process, session.isRunning else { return }
    // Запуск захвата выполняется после проверки разрешения.
}
```

Управление состоянием захвата должно быть последовательным. Ошибки операций, меняющих аудиорежим, обрабатываются явно; сообщения в интерфейсе — по-русски. Тестовые точки добавляются только там, где нужны для проверки реального жизненного цикла, без общей системы аудиобэкендов.

### Команды

Выполнять из корня проекта:

```bash
# Все существующие Python- и Swift-тесты.
bash scripts/test.sh

# Целевые тесты приложения; включает будущие регрессионные тесты захвата.
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox --build-system native --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --filter JarvisAppTests

# Проверка существующей обработки входного PCM.
python3 -m unittest discover -s voice -p 'test_audio_input.py'

# Сборка приложения и проверка подписи.
bash scripts/build.sh
codesign --verify --deep --strict 'dist/Джарвис.app'

# Ручной запуск собранного приложения для аппаратной проверки.
open 'dist/Джарвис.app'
```

### Стратегия проверки и критерии успеха

Автоматически проверить жизненный цикл с управляемыми ошибками: повторный start/stop; отказ до и после установки tap; ошибка применения обработки голоса; смена маршрута; выключение во время отложенного восстановления; перезапуск голосового процесса. Убедиться, что активен не более одного захвата, ресурсы очищаются, а устаревшие события игнорируются. Тесты должны проверять наблюдаемое поведение, а не просто количество вызовов метода очистки. Числовой порог покрытия не вводится; каждый перечисленный переход/отказ требует проверки. Существующие тесты проходят.

Обязательная аппаратная проверка на Mac пользователя, отдельно с `voice_processing: false` и `true`, с прежними настройками моделей:

1. Зафиксировать исходное состояние: при речи движется системная шкала и работает другое приложение с уже разрешённым микрофоном. Записать устройства, версию macOS и состояние Background Music.
2. После запуска Jarvis одновременно наблюдать его уровень и системную шкалу; проверить вход во втором приложении. Все три получают звук при речи в течение двух минут.
3. Выполнить 10 циклов выключения/включения микрофона и 5 перезапусков голосового режима. После готовности вход работает; выключенный захват не возобновляется сам.
4. Изменить аудиомаршрут и вернуть встроенные устройства 5 раз, используя уже доступные устройства и воспроизводимый сценарий диагностики. После стабилизации маршрута захват либо восстанавливается в пределах 5 секунд, либо освобождается с явной ошибкой. Системный вход остаётся работоспособным в обоих случаях.
5. Полностью завершить и снова запустить Jarvis 5 раз. Для восстановления микрофона не нужны перезагрузка Mac, перезапуск `coreaudiod` или изменение системных громкости/разрешений.
6. Зафиксировать до/после: время, фактический режим обработки, ошибки, поступление буферов и уровни, без записи речи. Повторяющиеся ошибки маршрута не должны скрываться за статусом готовности. Если один режим не поддерживается, явно подтвердить безопасный резервный захват.

Сборка и автоматические тесты не заменяют эту проверку. Исправление системного сбоя считается подтверждённым только после аппаратного сравнения. Проверки точности wake/запросов из основной спецификации сохраняются; в рамках регрессии проверить обращение и один запрос обычным голосом после восстановления.

### Границы

- **Всегда:** освобождать ресурсы после ошибки и остановки; сохранять выбранный файл настроек и фактическое значение `voice_processing`; ограничивать попытки восстановления; писать диагностику без аудио и ключей; отделять подтверждённые факты от гипотез.
- **Сначала согласовать:** новые зависимости/драйверы, изменение поддерживаемых устройств или минимальной версии macOS, удаление поддержки voice processing, изменение схемы конфигурации или её значений по умолчанию.
- **Никогда:** автоматически менять системный микрофон, громкость или mute; перезапускать системную аудиослужбу как часть исправления; удалять/отключать Background Music; менять личные ключи и настройки моделей; считать повышение чувствительности решением системного сбоя; выдавать успешные unit-тесты за аппаратное подтверждение.

### Открытые вопросы

- Является ли Background Music необходимым условием сбоя или только сопутствующим устройством? Ответ получить сравнением при реализации, не предполагать виновника.
- Устраняет ли полное освобождение движка сбой в обоих режимах обработки? Если нет, требуется дальнейшая локализация перед выбором другого механизма захвата.

Дополнение утверждено пользователем 2026-10-24. Технические вопросы выше остаются предметом проверки при реализации.
