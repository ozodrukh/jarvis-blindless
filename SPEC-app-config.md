# Spec: app-config

Approved scope: CAPABILITY-MAP.md; user authorized implementation on 2026-10-24.

## Objective and success criteria

The setup helper selects one JSON configuration file through the app. Its location, without copied credentials, survives app restarts. A validated selection applies after restarting voice services. Missing/invalid remembered files produce a useful error and preserve local operation. With no selected file, existing offline operation is the default. An example file documents every setting.

Configuration version 1 contains independently selectable `stt`, `llm`, and `tts` stages. Each selects `offline` or `online`, a model, and online base URL/credentials. Existing offline models are `whisper`, `gemma`, and `macos`. Credentials may be inline in a private file, referenced through an environment variable, or a file relative to the config. No credentials appear in the bridge summary, errors, or diagnostics. Unknown fields, invalid ranges, and non-HTTPS remote endpoints are rejected; loopback HTTP is allowed for testing. File size is bounded.

## Tech stack, structure, and code style

Swift 5.9/macOS 14; Python 3.12 standard library. `Sources/JarvisCore/ConfigurationSelection.swift` remembers the location; `voice/configuration.py` owns validation/defaults. Swift uses existing Foundation/Codable conventions; Python uses four-space indentation and explicit dictionaries, e.g. `settings = load_config(path)`.

## Commands and testing

`python3 -m unittest discover -s voice -p 'test_configuration.py'`

`swift test --disable-sandbox --build-system native --filter ConfigurationSelectionTests`

Test invalid types/ranges, credential redaction, missing credentials, config-relative paths, and remembered file location independently of real API calls. No numeric coverage gate; all boundary cases above require tests.

## Boundaries

Always validate before remembering a newly chosen file; preserve saved audiobook data. Ask first before adding another configuration format or secret-store dependency. Never log raw configuration or overwrite the user's config. The configuration owner supplies parsed settings to all consumers; no reverse dependency on audio or routing.

## Open questions

None blocking. Changes to a config file apply with the reload button; hot reload is outside scope.

## Расширение TTS (согласовано, 2026-10-24)

Контракт новых полей `tts.response_format`, `tts.pcm_sample_rate_hz` и `tts.pcm_channels`, их значений по умолчанию, проверки и обратной совместимости определён в разделе «Дополнение: формат выхода TTS» в `SPEC-model-routing.md`. Этот раздел является единственным источником нового контракта; пользователь согласовал его и явно поручил реализацию. Версия конфигурации остаётся `1`; существующее поведение без новых полей сохраняется. Реализация отслеживается в разделе TTS в `tasks/todo.md`.
