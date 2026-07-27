@preconcurrency import AVFoundation
import Foundation
import WhisperKit
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Whisper")

/// Whisper model choices exposed in Settings. rawValue is the WhisperKit model name.
public enum WhisperModelOption: String, CaseIterable, Sendable {
    case baseEn = "base.en"
    case smallEn = "small.en"
    case small = "small"
    case medium = "medium"
    case largeTurbo = "large-v3_turbo"

    public var label: String {
        switch self {
        case .baseEn: "Base (English) — fastest, ~150 MB"
        case .smallEn: "Small (English) — ~500 MB"
        case .small: "Small (multilingual) — ~500 MB"
        case .medium: "Medium (multilingual) — ~1.5 GB"
        case .largeTurbo: "Large v3 Turbo — best, ~1.6 GB"
        }
    }
}

/// Accumulates microphone audio as 16 kHz mono Float32 — Whisper's input format.
final class WhisperAudioRecorder: @unchecked Sendable {
    static let whisperSampleRate: Double = 16_000
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false
    )!

    func prepare(inputFormat: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        samples = []
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        // convert(to:error:withInputFrom:) invokes this block synchronously on the
        // calling thread, but its type is @Sendable — nonisolated(unsafe) avoids a
        // spurious strict-concurrency warning on this single-threaded mutable flag.
        nonisolated(unsafe) var fed = false
        converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        // AVAudioConverter buffers "trailing frames" of filter latency internally and
        // only flushes them once the input signals .endOfStream; without a reset here,
        // every call after the first would return 0 frames (the converter treats the
        // stream as finished). Resetting after each self-contained buffer keeps sample
        // counts accurate per `append` call, at the cost of minor filtering artifacts
        // at each buffer boundary.
        converter.reset()
        guard error == nil, let channel = out.floatChannelData else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples = []
        converter = nil
        return result
    }
}

enum WhisperServiceError: Error, LocalizedError {
    case modelNotLoaded
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model is not downloaded yet. Open Settings → General to download it."
        case .microphonePermissionDenied: "Microphone permission is required. Please grant access in System Settings."
        }
    }
}

/// Local Whisper transcription via WhisperKit (CoreML). Supports hotword
/// biasing through the decoder prompt — Apple's engine has no equivalent.
public final class WhisperService: TranscriptionBackend, @unchecked Sendable {
    private let modelName: String
    private let language: String?
    private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private let recorder = WhisperAudioRecorder()

    public init(modelName: String = WhisperModelOption.baseEn.rawValue, language: String? = "en") {
        self.modelName = modelName
        self.language = language
    }

    /// Downloads (if needed) and loads the CoreML model. Idempotent.
    public func preloadModel() async throws {
        guard whisperKit == nil else { return }
        logger.notice("Loading Whisper model: \(self.modelName)")
        whisperKit = try await WhisperKit(WhisperKitConfig(model: modelName))
        logger.notice("Whisper model ready")
    }

    public func startCapture() async throws {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { throw WhisperServiceError.microphonePermissionDenied }

        // Kick off model load concurrently with recording — usually cached.
        Task { try? await self.preloadModel() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        recorder.prepare(inputFormat: format)
        let recorder = self.recorder
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recorder.append(buffer)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    public func stopCapture(hotwordPrompt: String?) async throws -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        let samples = recorder.finish()
        guard !samples.isEmpty else { return "" }

        try await preloadModel()
        guard let whisperKit else { throw WhisperServiceError.modelNotLoaded }

        var options = DecodingOptions()
        options.language = language
        options.temperature = 0
        options.skipSpecialTokens = true
        if let prompt = hotwordPrompt, let tokenizer = whisperKit.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                options.usePrefillPrompt = true
            }
        }

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancelCapture() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        _ = recorder.finish()
    }
}
