import Foundation

/// The state of the transcription pipeline.
public enum PipelineState: Sendable {
    case idle
    case recording
    case transcribing
    case polishing
    case done(TranscriptionResult)
    case error(String)
    case cancelled
}

/// The result of a transcription + polish cycle.
public struct TranscriptionResult: Sendable, Codable, Identifiable {
    public let id: UUID
    public let rawText: String
    public let polishedText: String
    public let date: Date

    public init(rawText: String, polishedText: String) {
        self.id = UUID()
        self.rawText = rawText
        self.polishedText = polishedText
        self.date = Date()
    }
}
