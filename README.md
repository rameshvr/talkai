<p align="center">
  <img src="Assets/logo.svg" width="128" height="128" alt="TalkAI Logo">
</p>

<h1 align="center">TalkAI</h1>

<p align="center">
  A lightweight macOS menu bar utility that adds AI-powered text cleanup to voice input — completely local, no servers, no data leaving your device.
</p>

<p align="center">
  Press a hotkey, speak, press again. Your speech is transcribed and polished by AI, then pasted into whatever app you're using.
</p>

---

## Install

### Download DMG

Download the latest `.dmg` from [GitHub Releases](https://github.com/rameshvr/talkai/releases), open it, and drag TalkAI to Applications.

> On first launch, macOS may show a security warning because the app isn't notarized. **Right-click the app and choose "Open"** to proceed. This only happens once.

### Homebrew

```bash
brew tap rameshvr/talkai
brew install --cask talkai
```

### Build from Source

```bash
git clone https://github.com/rameshvr/talkai.git
cd talkai
./build-app.sh
open .build/app/TalkAI.app
```

Requires Xcode 26 and macOS 26.

## How It Works

TalkAI runs a two-stage local pipeline:

1. **Speech-to-text** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) transcribes your speech on-device (Apple's `SpeechTranscriber` is also available as an alternate engine). While you speak, TalkAI optionally captures the active window and uses on-device Vision OCR to read the text on screen, then feeds those words to Whisper as hotword bias — so names, identifiers, and technical terms it can see are more likely to be recognized correctly.
2. **AI polish** — the raw transcript is cleaned up by a local or on-device LLM: [Ollama](https://ollama.com) (`qwen2.5:3b`), Apple's on-device Foundation Models (default), or a cloud API if you opt in. When screen context is enabled, the same on-screen text and window/app metadata are passed to the polish step too, so the AI can match tone and terminology to what you're working on.

Everything runs locally by default — no audio, screenshot, or text leaves your Mac unless you deliberately choose the Cloud API backend.

## Usage

1. Press **Right ⌥ Option** to start recording
2. Speak naturally
3. Press **Right ⌥ Option** again to stop
4. Your polished text is automatically pasted into the focused app
5. Press **ESC** at any time to cancel

## Requirements

- macOS 26 or later
- Apple Silicon (M1 or later)
- Optional, for the **Apple** polish backend: Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Optional, for the **Ollama** polish backend: [Ollama](https://ollama.com) installed and running locally with a model pulled (e.g. `ollama pull qwen2.5:3b`)
- Optional: Screen Recording permission, only needed if you enable "Use screen context"

## Permissions

On first launch, TalkAI will ask for:

| Permission | Why |
|---|---|
| **Microphone** | To capture your speech |
| **Accessibility** | For global hotkey capture and paste simulation |
| **Apple Intelligence** *(optional)* | Only needed for the Apple on-device polish backend |
| **Screen Recording** *(optional)* | Only needed if you enable "Use screen context" |

To grant Accessibility access: **System Settings → Privacy & Security → Accessibility → Enable TalkAI**

## Settings

Access settings from the menu bar icon:

- **Transcription Engine** — Whisper (recommended, runs fully offline after a one-time model download) or Apple Speech; pick a Whisper model size and language
- **AI Cleanup** — Toggle "Polish with AI" on/off, and customize the cleanup prompt
- **Model Backend** — Choose Ollama (Local), Apple On-Device, or Cloud API for the polish step, with per-backend configuration (host/port/model for Ollama, API key/model for Cloud)
- **Use screen context** — Capture the active window, extract on-screen text on-device via Vision OCR, and use it to bias transcription and improve AI polishing accuracy across any backend
- **History** — View and re-copy recent transcriptions

## FAQ

**How is this different from built-in macOS Dictation?**

Built-in Dictation transcribes your speech verbatim. TalkAI adds an AI polishing step on top — it cleans up filler words, fixes grammar, and restructures your speech into well-formed text. The cleanup prompt is fully customizable, so you can tailor it for different tasks like coding, writing emails, or taking casual notes. One press-speak-press flow, no extra steps.

**Why not just use Dictation + Writing Tools?**

Writing Tools requires a separate manual step after dictating — select text, invoke Writing Tools, pick a rewrite option. TalkAI combines transcription and polishing into a single action. Plus, TalkAI's prompt is customizable for specialized use cases that Writing Tools doesn't cover (e.g., "output valid Swift code" or "keep technical jargon intact").

## Architecture

```
TalkAICore/          # Reusable Swift package (iOS-ready)
├── WhisperService   # On-device speech-to-text (WhisperKit)
├── SpeechService    # Alternate on-device speech-to-text (Apple)
├── OCRService       # On-device Vision OCR for screen context
├── PolishService    # LLM text cleanup (Apple / Ollama / Cloud backends)
└── Pipeline         # Orchestrator

TalkAI/              # macOS app
├── HotkeyManager    # Global hotkey (CGEvent)
├── ScreenshotService# Active window capture for screen context
├── PasteManager     # Clipboard + Cmd+V simulation
├── RecordingOverlay # Floating status indicator
└── Settings         # Configuration UI
```

## License

MIT
