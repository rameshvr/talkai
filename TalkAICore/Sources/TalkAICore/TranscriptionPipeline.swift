import Foundation
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Pipeline")

/// Orchestrates the full transcription pipeline: record → transcribe → polish.
@Observable
public final class TranscriptionPipeline: @unchecked Sendable {
    public private(set) var state: PipelineState = .idle

    private var sttBackend: any TranscriptionBackend
    public let polishService: PolishService
    private var processingTask: Task<Void, Never>?

    public var polishInstruction: String = PolishService.defaultInstruction

    /// When false, skip the polish stage entirely and paste raw transcription.
    public var polishEnabled: Bool = true

    /// Glossary line biasing STT recognition. Set before stop().
    public var hotwordPrompt: String?

    /// Context about the user's active application, set before stopping.
    public var context: PolishContext?

    public init(
        sttBackend: any TranscriptionBackend = SpeechService(),
        backend: any PolishBackend = ApplePolishBackend()
    ) {
        self.sttBackend = sttBackend
        self.polishService = PolishService(backend: backend)
    }

    /// Whether the current backend is available for polishing.
    public var isLLMAvailable: Bool {
        polishService.isAppleBackendAvailable
    }

    /// Swap the STT engine. Ignored while recording/processing.
    public func setSTTBackend(_ backend: any TranscriptionBackend) {
        guard case .idle = state else { return }
        sttBackend = backend
    }

    /// Update the locale used for speech recognition (Apple backend only).
    public func setLocale(_ locale: Locale) {
        (sttBackend as? SpeechService)?.locale = locale
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
            try await sttBackend.startCapture()
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
                let rawText = try await sttBackend.stopCapture(hotwordPrompt: hotwordPrompt)
                logger.notice("Raw transcription: '\(rawText)'")

                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    logger.warning("Empty transcription, returning to idle")
                    await MainActor.run { state = .idle }
                    return
                }

                var polishedText = rawText
                var polishError: String? = nil

                if polishEnabled {
                    await MainActor.run { state = .polishing }
                    logger.notice("Polishing text...")
                    do {
                        polishedText = try await polishService.polish(
                            rawText,
                            instruction: polishInstruction,
                            context: context ?? PolishContext()
                        )
                    } catch {
                        logger.error("Polish failed, pasting raw text: \(error.localizedDescription)")
                        polishError = error.localizedDescription
                    }
                }

                let result = TranscriptionResult(rawText: rawText, polishedText: polishedText, polishError: polishError)
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
        await sttBackend.cancelCapture()
        processingTask?.cancel()
        processingTask = nil
        state = .cancelled
        state = .idle
    }

    /// Reset to idle state after consuming a result.
    public func reset() {
        processingTask?.cancel()
        processingTask = nil
        state = .idle
    }
}
