# Capability Map: configurable online/offline Jarvis voice

Status: approved by the user on 2026-10-24, with explicit authorization to implement. Detailed specs and implementation checkpoints are recorded alongside this map and in `tasks/`.

## Confirmed intent

Select a configuration file once during setup and remember it across restarts. Wake-word detection always runs offline. Speech recognition, LLM, and TTS each have configurable online/offline model selection. Online selections retry failures within a bounded wait, then fall back to existing local engines; offline selections stay local. End an active conversation by voice or a configurable silence timeout. Investigate and improve normal-volume wake and request recognition using the Mac's built-in microphone and speakers.

## Proposed architecture decision

Extend the current Swift/Python foundation with the boundaries below. Defer SwiftAgent adoption. Keep the current macOS 14 baseline and installed local engines. Supporting evidence and future Telegram considerations: [framework review](docs/architecture/agent-framework-review.md).

## Capability boundaries

| Module id | Responsibility | Depends on | Spec after map approval |
|---|---|---|---|
| `app-config` | File selection and remembered location; validated configuration for providers, local model selection, capture, and conversation settings; usable errors and credential redaction. | — | `SPEC-app-config.md` |
| `audio-input` | Built-in microphone capture, offline wake detection, speech boundaries, input-level diagnostics, and measured normal-volume reliability. Produces captured audio and local control events. | `app-config` | `SPEC-audio-input.md` |
| `model-routing` | Speech recognition, LLM, and TTS adapters; supported model combinations; bounded retries/timeouts; existing local fallbacks; provider/timing observations for speed comparisons. | `app-config` | `SPEC-model-routing.md` |
| `conversation` | Active/idle conversation state, explicit end-chat and silence exit, whole-turn cancellation, coordination of input/model/output, and existing validated audiobook action execution. | `app-config`, `audio-input`, `model-routing` | `SPEC-conversation.md` |

Build order: `app-config` → `audio-input` and `model-routing` → `conversation`.

These are capability/spec boundaries, not a requirement for separate packages. Existing audiobook playback and progress persistence remain existing application capabilities. Shared contracts belong to the provider module's spec; consumers must not introduce reverse dependencies.

## Boundaries to preserve

- Wake detection and idle listening do not need the network. Ending chat returns to wake-word waiting.
- Conversation inactivity is distinct from the short pause that ends an individual utterance.
- Existing Whisper/Gemma/macOS speech are the local engines in scope; independent selections need an explicit capability matrix because Gemma currently accepts audio directly.
- End-chat handling must remain available when a remote provider fails. The conversation spec must define supported interruption states and the local control-recognition path.
- Cancelled or obsolete turns cannot speak or execute actions. Provider retries and TTS fallback cannot repeat completed actions.
- Saved audiobook positions and restart confirmation retain their current protections. Secrets and raw user audio do not enter ordinary diagnostics.
- Speed comparison needs to identify the actual provider/fallback used and separate recognition, LLM, synthesis, and total latency.

## Deferred capabilities

Telegram channels and actions, new local model engines, speaker identity/addressing detection, autonomous multi-tool planning, and a general plugin system. Telegram's future role (channel, personal-account integration, actions, or a combination) needs separate clarification when that work begins.

## Review gate

The user approved this map and explicitly requested implementation on 2026-10-24. The four module specs and `tasks/plan.md` record the resulting contracts and checkpoints. Implementation and automated verification are complete; outstanding real-user/provider checks are stated in `docs/verification.md`.
