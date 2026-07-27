# TalkAI Dictation Quality — Design

**Date:** 2026-07-26
**Goal:** Match or exceed Vibing's dictation quality (especially screenshot-context awareness) while staying fully local, with Apple Intelligence turned off and no heavy vision models.

## Background

Analysis of Vibing (closed-source app; cloud pipeline confirmed from its public repo/docs) identified four quality levers:

1. Strong single-pass ASR (VibeVoice-ASR-7B) with **hotword biasing at the recognition stage**
2. A **context bundle** sent with audio: screenshot + active input-field text + frontmost app name
3. **App-aware tone** in the LLM rewrite (chat vs. document)
4. Two-stage pipeline: ASR, then LLM rewrite

TalkAI today misses all four in the user's configuration:

- The default Apple Foundation Models polish backend requires Apple Intelligence. With it off, polish fails and the silent-failure fallback pastes **raw unpolished text** — no context is ever applied.
- Screenshot capture is gated on `supportsVision`, which is false for the default backend, so screenshots are never taken.
- No vocabulary hints reach the speech recognizer (`transcriptionOptions: []`).
- No focused-field text is captured; app name is a bare mention in the prompt.
- Bug: pipeline result wait caps at 30s while backend requests time out at 60s — late results are silently dropped.

## Decisions (agreed with user)

- **Transcription:** embed **WhisperKit** (SPM-native, CoreML/ANE-accelerated Whisper with decoder prompt biasing and in-app model downloads). *Amended from whisper.cpp during planning: whisper.cpp removed SPM support (xcframework-only), and TalkAI is a pure SPM package with no Xcode project — WhisperKit delivers the same design intent and actually integrates.* The user's installed Python `openai-whisper` proves Whisper accuracy but is too slow to shell out to interactively. Existing Apple `SpeechService` remains as a selectable fallback STT.
- **Screen context via OCR, not a vision LLM:** Apple Vision framework (`VNRecognizeTextRequest`, accurate mode) extracts on-screen text. Vision framework is independent of Apple Intelligence and works with it off.
- **Polish:** toggleable LLM rewrite stage. Default backend: **Ollama with a small text-only model (`qwen2.5:3b`, ~2 GB)** — OCR removes the need for vision models. Polish **off** = Whisper output pasted directly.
- VibeVoice-ASR-7B rejected: same weight class as the heavy models already ruled out.

## Architecture

```
Hotkey press
  ├─ ContextService (parallel with mic startup)
  │    ├─ app name + window title        (existing ScreenshotService metadata)
  │    ├─ screenshot (existing capture)  → OCRService (Vision) → screen text
  │    ├─ focused-field text (AX kAXValueAttribute, best-effort)
  │    └─ HotwordExtractor: proper nouns / identifiers from screen text,
  │       deduped + ranked, capped to Whisper's initial_prompt budget (~224 tokens)
  ├─ Recording (existing AVAudioEngine capture)
Hotkey release
  ├─ WhisperService.transcribe(audio, initialPrompt: hotwords)
  ├─ PolishService (if enabled)
  │    └─ prompt = cleanup instruction + app-aware tone rule
  │             + screen text (OCR) + focused-field text + app/window names
  │             + screenshot image ONLY for vision-capable backends
  └─ Paste (existing PasteManager)
```

### Components

**`OCRService`** (new, TalkAICore — *amended during planning: Vision needs no entitlements, and TalkAICore placement makes OCR unit-testable with rendered fixture images*): takes PNG `Data`, returns recognized text lines. `HotwordExtractor` also in TalkAICore (pure logic). `VNRecognizeTextRequest` with `.accurate`, language correction on.

**`HotwordExtractor`** (new, pure function — unit-testable): screen text → ranked hotword string. Heuristics: capitalized multi-word names, camelCase/snake_case identifiers, words not in system dictionary; dedupe; cap total length. Output feeds both Whisper `initial_prompt` and the polish prompt's "terms on screen" list.

**`FocusedFieldReader`** (new): AX API read of the focused element's value (and selected text). Best-effort — returns nil quietly when the app blocks AX. Truncate to a sane limit (e.g. 2,000 chars around the caret/end).

**`WhisperService`** (new, conforms to a new `TranscriptionBackend` protocol alongside existing `SpeechService`): wraps whisper.cpp via SPM (SwiftWhisper or direct C interop), Metal enabled. Model files (ggml format) downloaded on first use to Application Support; settings picker offers `base.en` / `small` / `medium` / `large-v3-turbo` with size labels. Existing `.pt` files from openai-whisper are not reusable (different format) — noted in UI copy.

**`PolishService` / backends** (modified):
- System instruction gains an app-aware tone rule: chat-like apps (Slack, Messages, Discord) → conversational, keep emotion; editors/IDEs/terminals → literal, preserve technical phrasing; mail/docs → clear professional prose. Keyed off bundle ID / app name.
- User prompt gains structured context blocks: `Text visible on screen:`, `Existing text in the field being typed into:`, plus the current app/window line. Screenshot image attached only when backend `supportsVision`.
- Temperature pinned low (0.2) for Ollama and Cloud backends (deterministic rewriting).
- Default Ollama model changes to `qwen2.5:3b`; settings default backend becomes Ollama when Foundation Models are unavailable.

### Settings changes

- STT engine picker: Whisper (default) / Apple Speech.
- Whisper model picker + download/progress UI.
- "Polish with AI" toggle (existing concept, now first-class: off = raw Whisper output).
- Screen context toggle now controls OCR + metadata for **all** backends (no longer gated on vision support).

## Error handling

| Failure | Behavior |
|---|---|
| Polish backend down/error | Paste raw transcription, **show a visible indicator** (overlay state / menu-bar flash + last-error in menu) — never silent |
| Late polish result (past wait) | Align wait timeout with backend timeout (single shared constant) |
| Whisper model missing | Overlay message + settings deep-link to download |
| OCR returns nothing / AX blocked | Proceed without that context block — degrade gracefully, log |
| Screenshot permission missing | Existing permission flow; OCR skipped |

## Testing

- Unit: `HotwordExtractor` (ranking, cap, dedupe), prompt assembly (context blocks appear/omit correctly, tone rule selection by bundle ID), timeout constant alignment.
- Integration: `WhisperService` transcribes a bundled fixture WAV; `initial_prompt` measurably biases a fixture containing an ambiguous proper noun.
- Manual E2E: dictate into a code editor with an unusual identifier on screen; verify the identifier is spelled correctly with polish on and off.

## Out of scope

- VibeVoice-ASR / Parakeet integration (revisit if Whisper accuracy disappoints)
- Streaming polish output
- Cloud backend prompt work beyond the shared template changes
- Custom vocabulary UI (hotwords are automatic from screen)

## Build note

macOS revokes Accessibility/Screen Recording permissions when the app binary changes — batch changes and rebuild deliberately during implementation.
