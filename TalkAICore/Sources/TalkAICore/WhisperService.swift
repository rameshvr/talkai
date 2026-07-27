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

/// Accumulates microphone audio at its native format and converts to 16 kHz
/// mono Float32 — Whisper's input format — in one shot at `finish()`.
///
/// Resampling per-tap (every ~1024 frames / ~21ms) would cold-start and
/// force-flush the converter's FIR filter at every buffer boundary, injecting
/// a filtering artifact at every one of those boundaries for the whole
/// recording. Deferring the resample to a single call over the full,
/// raw-rate recording avoids that: the artifact only occurs once, at the
/// very edges of the utterance. Whisper transcription only ever happens
/// after `stopCapture()`, so there's no latency cost to waiting.
final class WhisperAudioRecorder: @unchecked Sendable {
    static let whisperSampleRate: Double = 16_000
    private let lock = NSLock()
    private var inputFormat: AVAudioFormat?
    private var channelSamples: [[Float]] = []
    private var frameCount = 0
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false
    )!

    /// Frames captured so far — lets tests verify the mic is actually
    /// delivering audio without draining the recording.
    var capturedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frameCount
    }

    func prepare(inputFormat: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        self.inputFormat = inputFormat
        channelSamples = Array(repeating: [], count: Int(inputFormat.channelCount))
        frameCount = 0
    }

    /// Stores this buffer's raw samples at the hardware's native rate/channel count.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0..<channelSamples.count {
            channelSamples[channel].append(contentsOf: UnsafeBufferPointer(start: channelData[channel], count: frames))
        }
        frameCount += frames
    }

    /// Converts the whole accumulated recording to 16 kHz mono Float32 in a single pass.
    func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let inputFormat = self.inputFormat
        let channelSamples = self.channelSamples
        let frameCount = self.frameCount
        self.inputFormat = nil
        self.channelSamples = []
        self.frameCount = 0

        guard let inputFormat, frameCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let inChannelData = inBuffer.floatChannelData
        else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<channelSamples.count {
            channelSamples[channel].withUnsafeBufferPointer { source in
                inChannelData[channel].update(from: source.baseAddress!, count: frameCount)
            }
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var error: NSError?
        // convert(to:error:withInputFrom:) invokes this block synchronously on the
        // calling thread, but its type is @Sendable — nonisolated(unsafe) avoids a
        // spurious strict-concurrency warning on this single-threaded mutable flag.
        nonisolated(unsafe) var fed = false
        converter.convert(to: out, error: &error) { _, outStatus in
            // .endOfStream (rather than .noDataNow) tells the converter to
            // synthesize any remaining trailing filter-latency samples as
            // silence right now instead of waiting for more input that will
            // never arrive — without it, ~15% of the tail is silently dropped.
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard error == nil, let outChannel = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: outChannel[0], count: Int(out.frameLength)))
    }
}

public enum WhisperServiceError: Error, LocalizedError {
    case modelNotLoaded
    case microphonePermissionDenied

    public var errorDescription: String? {
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
    private let loadLock = NSLock()
    private var loadTask: Task<Void, Error>?
    /// Created lazily on first capture and reused for every recording —
    /// stopped between recordings but never discarded. Recreating the engine
    /// per recording tears down and rebuilds its HAL aggregate device each
    /// time; in the app process every rebuilt instance recorded pure silence
    /// while the first one worked (unified-log evidence in
    /// .superpowers/sdd/2026-07-26-dictation-quality/debug-empty-audio-report.md).
    private var audioEngine: AVAudioEngine?
    private let recorder = WhisperAudioRecorder()

    /// Frames captured in the in-progress recording (test/diagnostic peek).
    var capturedFrameCount: Int { recorder.capturedFrameCount }

    public init(modelName: String = WhisperModelOption.baseEn.rawValue, language: String? = "en") {
        self.modelName = modelName
        self.language = language
    }

    /// Downloads (if needed) and loads the CoreML model. Idempotent, and
    /// safe to call concurrently: all callers await one shared load instead
    /// of racing `whisperKit == nil` and loading the model twice.
    public func preloadModel() async throws {
        guard whisperKit == nil else { return }
        let task = modelLoadTask()
        do {
            try await task.value
        } catch {
            clearFailedLoadTask(task)  // allow retry after failure
            throw error
        }
    }

    private func clearFailedLoadTask(_ task: Task<Void, Error>) {
        loadLock.lock(); defer { loadLock.unlock() }
        if loadTask == task { loadTask = nil }
    }

    /// Returns the single in-flight load task, creating it if needed.
    private func modelLoadTask() -> Task<Void, Error> {
        loadLock.lock(); defer { loadLock.unlock() }
        if let loadTask { return loadTask }
        let task = Task {
            logger.notice("Loading Whisper model: \(self.modelName)")
            self.whisperKit = try await WhisperKit(WhisperKitConfig(model: self.modelName))
            logger.notice("Whisper model ready")
        }
        loadTask = task
        return task
    }

    public func startCapture() async throws {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { throw WhisperServiceError.microphonePermissionDenied }

        // Kick off model load concurrently with recording — usually cached.
        Task { try? await self.preloadModel() }

        let engine = audioEngine ?? AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        // Clear any tap left behind by an aborted previous run — installing
        // a second tap on the same bus crashes.
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        recorder.prepare(inputFormat: format)
        let recorder = self.recorder
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recorder.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    public func stopCapture(hotwordPrompt: String?) async throws -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
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
        _ = recorder.finish()
    }
}
