# TalkAI

A lightweight macOS menu bar utility that adds AI-powered text cleanup to voice input — completely local, no servers, no data leaving your device.

Press a hotkey, speak, press again. Your speech is transcribed and polished by AI, then pasted into whatever app you're using.

## How It Works

TalkAI uses two Apple frameworks that run entirely on your device:

- **SpeechTranscriber** — Apple's on-device speech-to-text engine
- **Foundation Models** — Apple's on-device ~3B parameter LLM (the same one powering Apple Intelligence)

No audio or text ever leaves your Mac.

## Usage

1. Press **Right ⌥ Option** to start recording
2. Speak naturally
3. Press **Right ⌥ Option** again to stop
4. Your polished text is automatically pasted into the focused app
5. Press **ESC** at any time to cancel

## Requirements

- macOS 26 or later
- Apple Silicon (M1 or later)
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Xcode 26 (to build from source)

## Build & Run

```bash
git clone https://github.com/yourusername/TalkAI.git
cd TalkAI
open Package.swift
```

Then press **Cmd+R** in Xcode to build and run.

## Permissions

On first launch, TalkAI will ask for:

| Permission | Why |
|---|---|
| **Microphone** | To capture your speech |
| **Accessibility** | For global hotkey capture and paste simulation |

To grant Accessibility access: **System Settings → Privacy & Security → Accessibility → Enable TalkAI**

## Settings

Access settings from the menu bar icon:

- **Language** — Choose transcription language (10 languages supported)
- **AI Cleanup Prompt** — Customize how the AI polishes your text
- **History** — View and re-copy recent transcriptions

## Architecture

```
TalkAICore/          # Reusable Swift package (iOS-ready)
├── SpeechService    # On-device speech-to-text
├── PolishService    # On-device LLM text cleanup
└── Pipeline         # Orchestrator

TalkAI/              # macOS app
├── HotkeyManager    # Global hotkey (CGEvent)
├── PasteManager     # Clipboard + Cmd+V simulation
├── RecordingOverlay # Floating status indicator
└── Settings         # Configuration UI
```

## License

MIT
