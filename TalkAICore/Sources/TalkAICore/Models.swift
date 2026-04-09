import Foundation

// MARK: - Model Backend Configuration

/// The type of model backend to use for polishing.
public enum ModelBackendType: String, Sendable, Codable, CaseIterable {
    case apple = "apple"
    case ollama = "ollama"
    case cloud = "cloud"

    public var displayName: String {
        switch self {
        case .apple: "Apple On-Device"
        case .ollama: "Ollama (Local)"
        case .cloud: "Cloud API"
        }
    }
}

/// Configuration for the Ollama backend.
public struct OllamaConfig: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var modelName: String
    public var isVisionModel: Bool

    public init(host: String = "localhost", port: Int = 11434, modelName: String = "llama3.2", isVisionModel: Bool = false) {
        self.host = host
        self.port = port
        self.modelName = modelName
        self.isVisionModel = isVisionModel
    }

    public var baseURL: String {
        "http://\(host):\(port)"
    }
}

/// Cloud API provider.
public enum CloudProvider: String, Sendable, Codable, CaseIterable {
    case claude = "claude"
    case openai = "openai"

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "OpenAI"
        }
    }

    public var defaultModel: String {
        switch self {
        case .claude: "claude-sonnet-4-20250514"
        case .openai: "gpt-4o"
        }
    }
}

/// Configuration for the Cloud API backend.
public struct CloudConfig: Sendable, Codable, Equatable {
    public var provider: CloudProvider
    public var apiKey: String
    public var modelName: String

    public init(provider: CloudProvider = .claude, apiKey: String = "", modelName: String = "") {
        self.provider = provider
        self.apiKey = apiKey
        self.modelName = modelName.isEmpty ? provider.defaultModel : modelName
    }

    public var isConfigured: Bool { !apiKey.isEmpty }
}

// MARK: - Pipeline State

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
