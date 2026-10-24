# Jarvis: agent framework review

Date: 2026-10-24. Status: recommendation accepted by the user, followed by explicit authorization to implement. No agent-framework dependency was added. Code observations below describe the original prototype examined during the architecture review; the resulting implementation is recorded in the root module specs and `docs/verification.md`.

## Recommendation

Keep the existing Swift app and Python local-model worker for this release. Add small, explicit boundaries for configuration, audio input, model routing, and conversation control. Defer SwiftAgent adoption until a concrete workflow needs its orchestration features and its deployment requirements are acceptable.

Future Telegram support benefits from separating input channels, model inference, and executable actions. It does not by itself require an agent framework. This is an architectural judgment based on the confirmed scope and the source review below.

The confirmed intent is: select one configuration file during setup and remember it; keep wake-word detection offline; independently configure online/offline speech recognition, LLM, and TTS; retry online failures before using existing local engines; end a conversation by voice or configurable silence; improve normal-volume speech capture with the Mac's built-in microphone and speakers. New local model engines and Telegram implementation are outside this release.

## Evidence and tradeoffs

| Concern | SwiftAgent | Extending Jarvis |
|---|---|---|
| Deployment | Release 2.0.1 declares Swift tools 6.2 and macOS 26. Reviewed main declares tools 6.4 and macOS 26. | Current package declares tools 5.9 and macOS 14. Keep this baseline unless a separately reviewed need changes it. |
| Conversation and tools | Typed pipelines, structured output, conversation sessions, cancellation, tool middleware, and optional MCP support are useful building blocks. | The current app has a short request/decision/action/reply flow. Explicit session state and validated action dispatch cover the present requirements. |
| Existing local inference | An adapter would still be needed for Jarvis's Python Gemma audio pipeline and its request cancellation protocol. | Preserve the installed models and bridge while making provider selection explicit. |
| Voice experience | Framework orchestration does not establish microphone gain, wake reliability, speech boundaries, or speaker echo behavior. | Measure and improve the existing audio path directly. |
| Future Telegram | A custom Telegram connection or application tool is still needed. | Add a channel or typed action to the same coordinator when its scope is defined. |

Platform declarations are verified in [SwiftAgent 2.0.1 Package.swift](https://github.com/1amageek/SwiftAgent/blob/2.0.1/Package.swift) and [the reviewed main Package.swift](https://github.com/1amageek/SwiftAgent/blob/cdeb70357a8d8e50bfe98fdf2de61636962583a1/Package.swift). Jarvis's baseline is in [Package.swift](../../Package.swift). Framework features are documented in [SwiftAgent's README](https://github.com/1amageek/SwiftAgent/blob/cdeb70357a8d8e50bfe98fdf2de61636962583a1/README.md) and [AgentSession](https://github.com/1amageek/SwiftAgent/blob/cdeb70357a8d8e50bfe98fdf2de61636962583a1/Sources/SwiftAgent/IO/AgentSession.swift).

These are deployment-target and toolchain findings, not a claim that an M1 cannot run the framework. Raising Jarvis's minimum macOS version would change the supported installation baseline.

## What adopting SwiftAgent would still leave us to build

### Provider behavior

OpenRouter exposes separate [speech recognition](https://openrouter.ai/docs/api/api-reference/stt/create-transcription) and [speech synthesis](https://openrouter.ai/docs/api/api-reference/tts/create-speech) endpoints. Recognition, reasoning, and synthesis must have separate settings and capability checks. Model names, supported languages, voices, audio encodings, and structured-output support depend on the selected service/model; one base URL does not establish all of them.

SwiftAgent's alternative model backend is enabled through OpenFoundationModels. Its OpenAI example and linked provider documentation need care: [EXAMPLE-OPENAI.md](https://github.com/1amageek/SwiftAgent/blob/cdeb70357a8d8e50bfe98fdf2de61636962583a1/EXAMPLE-OPENAI.md) references a provider repository now [marked deprecated in favor of AnyFoundationModels](https://github.com/1amageek/OpenFoundationModels-OpenAI). That is evidence of integration/documentation churn, not proof that current provider integration is broken. OpenRouter audio compatibility would require a focused integration check before adoption.

### Retries and fallback

The reviewed [RetryStep](https://github.com/1amageek/SwiftAgent/blob/cdeb70357a8d8e50bfe98fdf2de61636962583a1/Sources/SwiftAgent/ErrorHandling/RetryStep.swift) repeats any thrown error except cancellation and offers a fixed optional delay. Jarvis still needs application rules for transient failures, rate-limit delays, non-retryable credentials/configuration errors, and a bounded total wait before local fallback.

Proposed behavior for the module specs:

- Offline selection makes no remote request for that stage. Online selection prefers the configured service and falls back locally on failure, with bounded retries for retryable errors.
- Network reachability is a hint; actual request outcomes determine availability. A failed service must not be permanently disabled until app restart.
- Cancellation invalidates the whole turn, including retries and pending speech. A late response cannot speak or perform an action after the conversation ends.
- Retry inference separately from action execution. TTS failure falls back for the existing reply; it cannot rerun the LLM or repeat an audiobook action. Future message-sending actions will need the same separation and duplicate protection.

These rules are needed with either architecture.

### Existing local speech behavior

[voice/worker.py](../../voice/worker.py) currently sends the captured waveform directly to Gemma for recognition and decision generation. There is no standalone transcription stage in the command path. The installed Whisper model is currently used for wake detection.

Independent recognition/LLM selections therefore require adapters even without a framework migration. Reusing installed Whisper for local transcription is a candidate; its full-request accuracy and contention with wake detection must be verified. Preserve the existing Gemma audio route where appropriate, and make supported combinations explicit. Do not promise a new local recognizer or download another model under the existing-models-only scope.

### Listening reliability

The current sources provide several concrete investigation points:

- `voice/worker.py:143` uses a fixed RMS threshold of 0.006 to mark speech during capture; line 162 skips wake recognition below 0.002.
- `voice/logic.py:67` hard-codes a 15-second wait for initial speech; line 69 ends an utterance after a one-second pause. Conversation inactivity and a pause within one sentence need separate settings and semantics.
- `Sources/Jarvis/Controller.swift:111` rearms follow-up listening after ordinary replies. There is no explicit end-chat transition in that path.
- `Sources/Jarvis/VoiceBridge.swift` captures the input device and resamples audio. The reviewed code does not establish echo cancellation or measure normal-volume input quality.

These are software suspects, not a microphone-hardware diagnosis. Establish input level, noise floor, clipping, wake accuracy, and request accuracy on the actual built-in microphone, with speakers quiet and with audiobook playback. Select gain, threshold, or speech-activity changes from those results. An agent framework does not resolve those measurements.

## A small path to Telegram later

Keep one application coordinator responsible for session cancellation, context, and dispatching validated actions. Voice is its current input/output channel. Keep player actions and saved positions under application control, with model output treated as untrusted input; preserve restart confirmation.

Telegram can later connect in either direction:

1. A Telegram input/output adapter lets a person talk to Jarvis through Telegram.
2. Telegram actions let a person ask Jarvis to read or send messages.

Those are different capabilities and require their own scope, credentials, authorization, and delivery behavior. A bot channel can use Telegram's [HTTP Bot API](https://core.telegram.org/bots/api#making-requests). Personal-account access is a separate decision; bot support must not be presented as personal-account support.

SwiftAgent's [AgentConnection boundary](https://github.com/1amageek/SwiftAgent/blob/cdeb70357a8d8e50bfe98fdf2de61636962583a1/Sources/SwiftAgent/IO/AgentConnection.swift) is a useful reference for separating transport from conversation. Jarvis can keep that separation without importing its runtime or building a generic plugin system now.

Revisit a framework when real requirements include model-directed sequences of multiple tools, reusable complex workflows, or third-party MCP tools, and compare adoption against the coordinator that actually exists then. Preserve framework-neutral request, result, and action boundaries in the meantime.

## Proposed scope and next review

The proposed modules and dependency direction are in [CAPABILITY-MAP.md](../../CAPABILITY-MAP.md). They are specification boundaries; they do not require four packages or a broad rewrite.

Approve or revise that map and the recommendation before module specs are written. The module specs will establish configuration syntax, retry/time budgets, exact end-chat behavior, microphone acceptance targets, and executable validation commands.

## Review limits

Inspected local Swift/Python source, SwiftAgent release 2.0.1 and main commit `cdeb70357a8d8e50bfe98fdf2de61636962583a1`, selected runtime sources, and official service documentation. No framework was installed, compiled, or benchmarked; no paid model requests, microphone recordings, or Telegram actions were made. Latency, recognition quality, and the microphone root cause remain unmeasured.
