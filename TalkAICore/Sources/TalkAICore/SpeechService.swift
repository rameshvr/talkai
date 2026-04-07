@preconcurrency import AVFoundation
import Foundation
import Speech

enum SpeechServiceError: Error, LocalizedError {
    case noCompatibleAudioFormat
    case microphonePermissionDenied
    case localeNotAvailable(Locale)

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudioFormat:
            return "No compatible audio format available for speech transcription."
        case .microphonePermissionDenied:
            return "Microphone permission is required. Please grant access in System Settings."
        case .localeNotAvailable(let locale):
            return "Speech model for \(locale.identifier) is not available. Please check System Settings."
        }
    }
}

/// On-device speech-to-text using SpeechAnalyzer and SpeechTranscriber.
@Observable
public final class SpeechService: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, any Error>?

    private var finalizedTranscript = ""
    private var volatileTranscript = ""

    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Begin capturing audio and transcribing.
    public func startCapture() async throws {
        finalizedTranscript = ""
        volatileTranscript = ""

        // Request microphone permission if needed
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            throw SpeechServiceError.microphonePermissionDenied
        }

        // Create transcriber
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // Ensure speech model assets are installed for this locale
        if let request = try? await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        // Create analyzer with transcriber module
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Get the compatible audio format
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw SpeechServiceError.noCompatibleAudioFormat
        }

        // Set up audio engine
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        self.audioEngine = audioEngine

        // Create input stream for feeding audio to analyzer
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        // Start the analyzer
        try await analyzer.start(inputSequence: inputSequence)

        // Set up audio format converter if needed
        let needsConversion = recordingFormat.sampleRate != analyzerFormat.sampleRate
            || recordingFormat.channelCount != analyzerFormat.channelCount
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: recordingFormat, to: analyzerFormat)
            : nil

        // Install tap to feed audio to analyzer
        let capturedContinuation = self.inputContinuation
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * analyzerFormat.sampleRate / recordingFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: analyzerFormat,
                    frameCapacity: max(frameCapacity, 1)
                ) else { return }
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil else { return }
                capturedContinuation?.yield(AnalyzerInput(buffer: converted))
            } else {
                capturedContinuation?.yield(AnalyzerInput(buffer: buffer))
            }
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        // Collect results in background
        resultsTask = Task { [weak self] in
            guard let transcriber = self?.transcriber else { return }
            for try await result in transcriber.results {
                if result.isFinal {
                    self?.finalizedTranscript += String(result.text.characters)
                    self?.volatileTranscript = ""
                } else {
                    self?.volatileTranscript = String(result.text.characters)
                }
            }
        }
    }

    /// Stop capturing and return the raw transcription.
    public func stopCapture() async throws -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        inputContinuation?.finish()
        inputContinuation = nil

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await resultsTask?.value
        resultsTask = nil

        let result = finalizedTranscript + volatileTranscript
        analyzer = nil
        transcriber = nil
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cancel capture without returning a result.
    public func cancelCapture() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        finalizedTranscript = ""
        volatileTranscript = ""
    }
}
