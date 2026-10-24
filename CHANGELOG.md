# Changelog

## Unreleased — microphone recovery candidate

### Fixed

- Microphone capture now releases its engine and device observer on stop or failure, and uses a fresh engine on restart.
- Route recovery is bounded; late permission replies and callbacks cannot restart a disabled microphone.
- Readiness requires actual audio buffers. A stalled stream produces recovery or a clear retryable error; silence remains valid input.
- Pending audio delivery is bounded, and the displayed input level clears when capture stops.

### Verification limits

Automated lifecycle and UI state checks pass. The user confirmed that both the system and Jarvis input meters work after restarting with the new build and existing configuration. Repeated route/restart cycles and both processing modes still require validation; this candidate is not a fully hardware-verified release.

## 0.2.0 — 2026-10-24

### Added

- Remembered JSON configuration file selection and reload, with independent online/offline speech recognition, LLM, and TTS settings.
- OpenRouter/OpenAI-compatible requests, bounded retries, existing local fallbacks, and visible provider/timing information.
- Local end-chat commands, a configurable conversation timeout, and a button to end the conversation.
- Microphone level display, local speech-activity detection, quiet-speech normalization, and optional native voice processing.

### Fixed

- Cancelled requests and downloaded speech cannot act on a later conversation.
- Failed online speech playback uses local speech without repeating an audiobook action.
- End-chat commands remain local even when online transcription fails.

### Verification limits

Provider failure behavior is covered using a local HTTP fixture. Real paid services require a configured private key/model/voice. Prerecorded normal/quiet speech checks do not replace a live microphone and VoiceOver trial.
