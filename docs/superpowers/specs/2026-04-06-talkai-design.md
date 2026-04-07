# TalkAI — Design Spec

## Context

macOS has a built-in dictation tool, but it produces raw speech-to-text without cleanup. Apps like Vibing enhance dictation with AI but send audio to external servers. TalkAI is a lightweight macOS menu bar utility that adds AI-powered text cleanup to voice input while staying **completely local** — using Apple's on-device SpeechTranscriber for transcription and the Foundation Models framework (~3B param on-device LLM) for polishing.

The goal is a simple, keyboard-driven tool: press a hotkey, speak, press again, and polished text is pasted into whatever app is focused. No accounts, no servers, no data leaving the device.

## Architecture

Two layers: a reusable Swift package (TalkAICore) and a macOS app shell.

### TalkAICore (Swift Package)

Platform-independent package depending only on `Speech` and `FoundationModels` frameworks. Reusable for a future iOS app.

```
TalkAICore/
├── Sources/TalkAICore/
│   ├── SpeechService.swift
│   ├── PolishService.swift
│   ├── TranscriptionPipeline.swift
│   └── Models.swift
```

**SpeechService** — wraps SpeechAnalyzer/SpeechTranscriber:
- `startCapture()` — begins audio capture and transcription
- `stopCapture() async -> String` — stops and returns raw transcription
- Configurable locale
- Uses SpeechDetector internally for voice activity detection

**PolishService** — wraps FoundationModels LanguageModelSession:
- `polish(_ rawText: String, instruction: String) async -> String`
- Configurable system prompt (default: "Fix grammar, punctuation, and filler words. Keep the original tone.")
- Checks `SystemLanguageModel.default` availability before use

**TranscriptionPipeline** — orchestrator:
- `start()` / `stop() async -> TranscriptionResult`
- `TranscriptionResult` contains `rawText` and `polishedText`
- `@Observable` with published state: `idle` → `recording` → `transcribing` → `polishing` → `done`

### macOS App

```
TalkAI/
├── TalkAIApp.swift
├── HotkeyManager.swift
├── PasteManager.swift
├── RecordingOverlay.swift
├── SettingsView.swift
├── PermissionManager.swift
└── HistoryStore.swift
```

**TalkAIApp** — `@main` entry point with `MenuBarExtra` and `Settings` scene. Runs as menu bar app (`LSUIElement = true`). Optional launch-at-login via `SMAppService`.

**HotkeyManager** — `CGEvent.tapCreate` for global hotkey interception. Default: Right Option key. Requires Accessibility permission.

**PasteManager** — Saves current clipboard → writes polished text to `NSPasteboard` → simulates Cmd+V via `CGEvent` → restores previous clipboard after ~500ms delay.

**RecordingOverlay** — `NSPanel` with `.floating` level. Non-activating (doesn't steal focus). Observes pipeline state to show: pulsing recording indicator → "Processing..." → "Pasted!" → fade out.

**SettingsView** — SwiftUI settings window:
- Hotkey configuration
- Transcription language selection
- Editable cleanup prompt (system instruction for the LLM)
- Recent transcription history (raw + polished, tap to re-copy)

**PermissionManager** — First-launch onboarding:
- Checks Microphone permission
- Checks Accessibility permission
- Checks `SystemLanguageModel.default` availability (Apple Intelligence enabled)
- Guided flow if anything is missing

**HistoryStore** — Persists recent transcriptions locally (UserDefaults or JSON file).

## User Interaction Flow

1. **Idle** — Menu bar icon visible. No overlay.
2. **Hotkey pressed** — Floating pill overlay appears showing "Recording..." with pulsing indicator. Audio capture begins.
3. **User speaks** — Overlay stays visible with timer/waveform.
4. **Hotkey pressed again** — Overlay shows "Processing..." Audio stops. SpeechTranscriber finalizes → PolishService cleans up.
5. **Done** — Polished text copied to clipboard, Cmd+V simulated into focused app. Overlay briefly shows "Pasted!" then fades.
6. **ESC at any point** — Cancels, dismisses overlay, no output.

## Project Structure

```
talkai/
├── TalkAICore/                    # Swift Package (local)
│   ├── Package.swift
│   └── Sources/TalkAICore/
│       ├── SpeechService.swift
│       ├── PolishService.swift
│       ├── TranscriptionPipeline.swift
│       └── Models.swift
├── TalkAI/                        # macOS App (Xcode project)
│   ├── TalkAI.xcodeproj
│   ├── TalkAIApp.swift
│   ├── HotkeyManager.swift
│   ├── PasteManager.swift
│   ├── RecordingOverlay.swift
│   ├── SettingsView.swift
│   ├── PermissionManager.swift
│   ├── HistoryStore.swift
│   └── Info.plist
└── docs/
```

## Requirements

- macOS 26+ (for SpeechAnalyzer and FoundationModels)
- Apple Silicon (required for on-device LLM)
- Apple Intelligence enabled in System Settings
- Microphone permission
- Accessibility permission (for global hotkey + paste simulation)
- Distributed outside App Store (cannot be sandboxed)
- Open-source project on GitHub

## Distribution

- **GitHub Releases** — attach unsigned `.app` bundle (zipped) or `.dmg` for each release
- **Build from source** — primary path for users: clone repo, open in Xcode 26, Cmd+R
- **README** — setup instructions, requirements (macOS 26, Apple Silicon, Apple Intelligence enabled), permission walkthrough with screenshots
- **LICENSE** — MIT (simple, permissive) unless you prefer otherwise
- **.gitignore** — exclude `.superpowers/`, `.build/`, `DerivedData/`, `.DS_Store`

## Edge Cases

- **Apple Intelligence not enabled** → Alert on first launch with instructions to enable it
- **No microphone permission** → Prompt on first use
- **No Accessibility permission** → Guide user to System Settings > Privacy & Security
- **LLM unavailable** (low battery, Game Mode) → Fall back to raw transcription without polish, notify user
- **Empty transcription** (silence or noise) → No paste, overlay shows "Nothing detected" and fades
- **Clipboard restore** — Previous clipboard contents saved before overwrite and restored after paste completes

## Verification

1. **Build and run** the Xcode project on macOS 26 with Apple Silicon
2. **First launch** — verify permission onboarding flow appears for Mic + Accessibility
3. **Hotkey test** — press configured hotkey, verify overlay appears and audio capture starts
4. **Speak and stop** — press hotkey again, verify transcription + polish completes
5. **Paste test** — verify polished text is pasted into a focused text editor (TextEdit, Notes, etc.)
6. **Clipboard restore** — copy something to clipboard before using TalkAI, verify it's restored after paste
7. **ESC cancel** — start recording, press ESC, verify no output
8. **Settings** — verify hotkey change, language change, and prompt editing all take effect
9. **History** — verify recent transcriptions appear and can be re-copied
10. **Fallback** — disable Apple Intelligence, verify raw transcription is still pasted with a warning
