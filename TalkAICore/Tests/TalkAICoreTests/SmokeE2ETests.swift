import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import TalkAICore

/// Live, end-to-end smoke checks against the real Whisper model and a real
/// local Ollama server. Gated behind TALKAI_SMOKE=1 so `swift test` stays
/// fast and hermetic by default — these hit the network/filesystem and
/// download a ~150MB model on first run.
struct SmokeE2ETests {
    @Test func realWhisperTranscribesSynthesizedSpeech() async throws {
        guard ProcessInfo.processInfo.environment["TALKAI_SMOKE"] == "1" else { return }

        let audioURL = URL(fileURLWithPath: "/tmp/talkai-smoke.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioURL.path, "Hello world, testing TalkAI dictation"]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length))
        )
        try audioFile.read(into: buffer)

        // Mirror WhisperService's own path: hand raw hardware-rate audio to
        // the recorder and let it resample to 16 kHz mono Float32.
        let recorder = WhisperAudioRecorder()
        recorder.prepare(inputFormat: format)
        recorder.append(buffer)
        let samples = recorder.finish()
        #expect(!samples.isEmpty)

        // Downloads base.en (~150MB) from Hugging Face on first run.
        let whisperKit = try await WhisperKit(WhisperKitConfig(model: WhisperModelOption.baseEn.rawValue))

        // Mirror WhisperService.stopCapture's DecodingOptions, including the
        // hotword prefill-prompt path.
        var options = DecodingOptions()
        options.language = "en"
        options.temperature = 0
        options.skipSpecialTokens = true
        if let tokenizer = whisperKit.tokenizer {
            let tokens = tokenizer.encode(text: " Glossary: TalkAI.")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                options.usePrefillPrompt = true
            }
        }

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let transcript = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("SMOKE WHISPER TRANSCRIPT: \(transcript)")
        #expect(transcript.lowercased().contains("hello"))
    }

    @Test func liveOllamaPolishesDictatedText() async throws {
        guard ProcessInfo.processInfo.environment["TALKAI_SMOKE"] == "1" else { return }

        let backend = OllamaPolishBackend(config: OllamaConfig(modelName: "qwen2.5:3b"))
        let rawText = "um hello world this is uh a test"
        let context = PolishContext(appName: "TextEdit", screenText: "TalkAI Kaleido")

        let result = try await backend.polish(
            rawText, instruction: PolishService.defaultInstruction, context: context
        )

        print("SMOKE OLLAMA POLISH OUTPUT: \(result)")
        #expect(!result.isEmpty)
        #expect(result != rawText)

        let words = result.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        #expect(!words.contains("um"))
        #expect(!words.contains("uh"))
    }
}
