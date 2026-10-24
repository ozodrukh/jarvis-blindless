# Spec: conversation

Approved scope: CAPABILITY-MAP.md; user authorized implementation on 2026-10-24.

## Objective and success criteria

After activation, allow follow-ups until a locally recognized end phrase or configurable silence ends the chat. End chat stops pending inference, retries, synthesis, and playback; clears transient conversation/restart-confirmation state; returns to offline wake waiting. Audiobook playback stays paused and saved positions remain intact. Silence ends quietly; an explicit end command may receive a short local acknowledgement without reopening the chat.

Use one request generation and one speech generation to reject late responses. UI/button cancellation follows the same path as voice cancellation. A provider failure never prevents local end-chat recognition. Only validated current decisions reach BookPlayer. TTS failure cannot repeat that decision. Keep distinct input, model, and action boundaries so future Telegram work can connect without changing provider logic; Telegram is outside this implementation.

## Tech stack, structure, and code style

Existing SwiftUI controller, AVSpeechSynthesizer/AVAudioPlayer, Python JSON-lines worker. Preserve MainActor application state. `JarvisController` coordinates effects; worker handles cancellation tokens and emits typed event names. Example: `guard id == requestID else { return }` before applying a result.

## Commands and testing

`python3 -m unittest discover -s voice -p 'test_worker.py'`

`swift test --disable-sandbox --build-system native`

`bash scripts/build.sh` and `bash scripts/package.sh`.

Test silence and explicit end, end during provider work, stale decision/speech suppression, fresh activation, unchanged audiobook positions, and clearing pending restart confirmation. Verify all existing player tests. Check packaged worker/config example presence and local signature. UI and voice controls must have Russian labels and accessible names.

## Boundaries

Always keep cancellation independent of remote responses and existing saved-position protections. Never add broad filesystem/shell tools or send Telegram messages. Ask first before adding remote actions or persistent conversation history. Depends on app-config, audio-input, model-routing.

## Open questions

Live VoiceOver and normal-volume conversational checks remain part of the user trial.
