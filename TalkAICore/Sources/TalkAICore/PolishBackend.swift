import Foundation

/// Context about the user's active application when dictation started.
public struct PolishContext: Sendable {
    public let appName: String?
    public let windowTitle: String?
    public let screenshot: Data?

    public init(appName: String? = nil, windowTitle: String? = nil, screenshot: Data? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.screenshot = screenshot
    }
}

/// Builds the system instruction for polish backends, embedding context metadata
/// so models use it for understanding without echoing it in output.
public func polishSystemInstruction(context: PolishContext) -> String {
    var instruction = "You are a text rewriting tool. You only output rewritten text. You never explain, answer questions, or add commentary."
    var parts: [String] = []
    if let app = context.appName { parts.append(app) }
    if let title = context.windowTitle { parts.append("window: \(title)") }
    if !parts.isEmpty {
        instruction += " The user is currently typing in: \(parts.joined(separator: ", ")). Use this context to better understand their dictated text."
    }
    return instruction
}

/// Common protocol for all polish/rewrite backends.
public protocol PolishBackend: Sendable {
    /// Whether this backend is currently available and configured.
    var isAvailable: Bool { get async }

    /// Whether this backend supports image/vision input.
    var supportsVision: Bool { get }

    /// Human-readable display name for the settings UI.
    var displayName: String { get }

    /// Polish raw transcription text, optionally using visual context.
    func polish(_ rawText: String, instruction: String, context: PolishContext) async throws -> String
}
