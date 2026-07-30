import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import TalkAICore

/// Reproduces "second transcription empty" against the real Whisper model,
/// gated behind TALKAI_SMOKE=1. The app passes OCR hotwords as promptTokens +
/// usePrefillPrompt on every stopCapture; run 1 transcribes, runs 2+ return
/// empty near-instantly on the same reused WhisperKit instance.
struct PromptedTranscribeTests {
    /// Mirrors WhisperService.stopCapture's DecodingOptions exactly.
    private func options(
        whisperKit: WhisperKit, prompt: String?, usePrefill: Bool
    ) -> DecodingOptions {
        var options = DecodingOptions()
        options.language = "en"
        options.temperature = 0
        options.skipSpecialTokens = true
        if let prompt, let tokenizer = whisperKit.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                options.usePrefillPrompt = usePrefill
            }
        }
        return options
    }

    private func synthesizedSamples() throws -> [Float] {
        let audioURL = URL(fileURLWithPath: "/tmp/talkai-prompt2.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioURL.path, "Hello world, testing TalkAI dictation with prompts"]
        try say.run()
        say.waitUntilExit()
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFile.length))!
        try audioFile.read(into: buffer)
        let recorder = WhisperAudioRecorder()
        recorder.prepare(inputFormat: format)
        recorder.append(buffer)
        return recorder.finish()
    }

    private func transcribe(
        _ whisperKit: WhisperKit, _ samples: [Float], _ options: DecodingOptions
    ) async throws -> String {
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func promptedTranscribeMatrix() async throws {
        guard ProcessInfo.processInfo.environment["TALKAI_SMOKE"] == "1" else { return }

        let samples = try synthesizedSamples()
        #expect(!samples.isEmpty)
        let prompt = "Glossary: TalkAI."
        let kit = try await WhisperKit(WhisperKitConfig(model: WhisperModelOption.baseEn.rawValue))
        // Models (and thus the tokenizer) load lazily — force them so options
        // built below actually get promptTokens, like the app from run 2 on.
        try await kit.loadModels()
        #expect(kit.tokenizer != nil)

        // P1: FIRST prompted+prefill call on a fresh instance — expected to
        // reproduce the bug (call order is irrelevant once tokenizer exists).
        let p1 = try await transcribe(kit, samples, options(whisperKit: kit, prompt: prompt, usePrefill: true))
        print("DIAG P1 prompted first call: '\(p1)'")

        // P2/P3: candidate fix — disable the misfiring first-token guard.
        var fixed = options(whisperKit: kit, prompt: prompt, usePrefill: true)
        fixed.firstTokenLogProbThreshold = nil
        let p2 = try await transcribe(kit, samples, fixed)
        print("DIAG P2 prompted, threshold nil: '\(p2)'")
        let p3 = try await transcribe(kit, samples, fixed)
        print("DIAG P3 prompted, threshold nil, repeat: '\(p3)'")

        #expect(p2.lowercased().contains("hello"))
        #expect(p3.lowercased().contains("hello"))
    }
}
