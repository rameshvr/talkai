import Foundation

/// Context about the user's active application when dictation started.
public struct PolishContext: Sendable {
    public let appName: String?
    public let windowTitle: String?
    public let screenshot: Data?
    public let screenText: String?
    public let focusedFieldText: String?
    public let appBundleID: String?

    public init(
        appName: String? = nil,
        windowTitle: String? = nil,
        screenshot: Data? = nil,
        screenText: String? = nil,
        focusedFieldText: String? = nil,
        appBundleID: String? = nil
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.screenshot = screenshot
        self.screenText = screenText
        self.focusedFieldText = focusedFieldText
        self.appBundleID = appBundleID
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
        instruction += " The user is currently typing in: \(parts.joined(separator: ", "))."
    }
    if let tone = AppToneCategory.category(appName: context.appName, bundleID: context.appBundleID).toneInstruction {
        instruction += " " + tone
    }
    if context.screenshot != nil {
        instruction += " A screenshot of the user's active window is attached. Use it to understand the visual context — such as code, documents, UI elements, or data on screen — to make the rewritten text more accurate and relevant. For example, use correct variable names, technical terms, or proper nouns visible on screen."
    } else if !parts.isEmpty {
        instruction += " Use this context to better understand their dictated text."
    }
    return instruction
}

private let maxScreenTextChars = 1_500
private let maxFieldTextChars = 600

/// Builds the user prompt shared by all polish backends: instruction,
/// optional context blocks, then the dictated text.
public func polishUserPrompt(rawText: String, instruction: String, context: PolishContext) -> String {
    var sections: [String] = [instruction]

    if let screen = context.screenText?.trimmingCharacters(in: .whitespacesAndNewlines), !screen.isEmpty {
        let clipped = String(screen.prefix(maxScreenTextChars))
        sections.append("Text visible on the user's screen (reference for spelling and terminology — never copy it into the output):\n\(clipped)")
    }

    if let field = context.focusedFieldText?.trimmingCharacters(in: .whitespacesAndNewlines), !field.isEmpty {
        let clipped = String(field.suffix(maxFieldTextChars))
        sections.append("Existing text in the field being typed into (the dictation continues it):\n\(clipped)")
    }

    sections.append("Dictated text:\n\(rawText)")
    sections.append("Cleaned text:")
    return sections.joined(separator: "\n\n")
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
