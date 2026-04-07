import Foundation
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Pipeline")

/// Orchestrates the full transcription pipeline: record → transcribe → polish.
@Observable
public final class TranscriptionPipeline: @unchecked Sendable {
    public private(set) var state: PipelineState = .idle

    private let speechService: SpeechService
    private let polishService: PolishService
    private var processingTask: Task<Void, Never>?

    public var polishInstruction: String = PolishService.defaultInstruction

    public init(locale: Locale = .current) {
        self.speechService = SpeechService(locale: locale)
        self.polishService = PolishService()
    }

    /// Whether the on-device LLM is available for polishing.
    public var isLLMAvailable: Bool {
        polishService.isAvailable
    }

    /// Update the locale used for speech recognition.
    public func setLocale(_ locale: Locale) {
        speechService.locale = locale
    }

    /// Start recording. Transitions state from idle → recording.
    public func start() async {
        guard case .idle = state else {
            logger.warning("start() called but state is not idle: \(String(describing: self.state))")
            return
        }

        do {
            state = .recording
            logger.notice("Starting capture...")
            try await speechService.startCapture()
            logger.notice("Capture started successfully")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stop recording and process. Transitions recording → transcribing → polishing → done.
    public func stop() {
        guard case .recording = state else {
            logger.warning("stop() called but state is not recording: \(String(describing: self.state))")
            return
        }

        state = .transcribing
        logger.notice("Stopping capture, transitioning to transcribing...")

        processingTask = Task {
            do {
                let rawText = try await speechService.stopCapture()
                logger.notice("Raw transcription: '\(rawText)'")

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    logger.warning("Empty transcription, returning to idle")
                    await MainActor.run { state = .idle }
                    return
                }

                await MainActor.run { state = .polishing }
                logger.notice("Polishing text...")

                let polishedText = try await polishService.polish(rawText, instruction: polishInstruction)
                logger.notice("Polished text: '\(polishedText)'")

                let result = TranscriptionResult(rawText: rawText, polishedText: polishedText)
                await MainActor.run { state = .done(result) }
                logger.notice("Pipeline complete, state = done")
            } catch {
                logger.error("Processing failed: \(error.localizedDescription)")
                if !Task.isCancelled {
                    await MainActor.run {
                        state = .error("Processing failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Cancel the current operation and return to idle.
    public func cancel() async {
        logger.notice("Cancelling...")
        await speechService.cancelCapture()
        processingTask?.cancel()
        processingTask = nil
        state = .cancelled
        state = .idle
    }

    /// Reset to idle state after consuming a result.
    public func reset() {
        state = .idle
    }
}
