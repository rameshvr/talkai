import Foundation

/// A speech-to-text engine the pipeline can drive interchangeably.
public protocol TranscriptionBackend: AnyObject, Sendable {
    /// Begin capturing audio and transcribing.
    func startCapture() async throws
    /// hotwordPrompt: optional glossary line biasing recognition (Whisper only; Apple ignores it).
    func stopCapture(hotwordPrompt: String?) async throws -> String
    /// Cancel capture without returning a result.
    func cancelCapture() async
}
