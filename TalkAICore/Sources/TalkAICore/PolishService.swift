import Foundation
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Polish")

/// Routes polish requests to the active backend.
public final class PolishService: @unchecked Sendable {
    public static let defaultInstruction = """
        Rewrite the following dictated text with correct grammar, punctuation, and capitalization. \
        Remove filler words like um, uh, like, you know. \
        Keep the original meaning and tone. Output only the cleaned text.
        """

    private var _backend: any PolishBackend

    public init(backend: any PolishBackend = ApplePolishBackend()) {
        self._backend = backend
    }

    /// The currently active backend.
    public var backend: any PolishBackend {
        get { _backend }
        set { _backend = newValue }
    }

    /// Whether the current backend is available.
    public var isAvailable: Bool {
        get async { await _backend.isAvailable }
    }

    /// Check availability synchronously (for Apple backend only).
    public var isAppleBackendAvailable: Bool {
        (_backend as? ApplePolishBackend)?.isAvailable ?? false
    }

    /// Polish raw transcription text using the active backend.
    public func polish(
        _ rawText: String,
        instruction: String = PolishService.defaultInstruction,
        context: PolishContext = PolishContext()
    ) async throws -> String {
        logger.notice("Polishing with backend: \(self._backend.displayName)")
        return try await _backend.polish(rawText, instruction: instruction, context: context)
    }
}
