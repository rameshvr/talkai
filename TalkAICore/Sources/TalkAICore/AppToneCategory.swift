import Foundation

/// Coarse category of the app being dictated into, driving output tone.
public enum AppToneCategory: Sendable, Equatable {
    case chat, codeEditor, terminal, email, document, generic

    private static let chatApps = ["slack", "discord", "messages", "telegram", "whatsapp", "signal"]
    private static let codeApps = ["xcode", "visual studio code", "code", "cursor", "zed", "intellij", "pycharm", "sublime"]
    private static let terminalApps = ["terminal", "iterm", "warp", "ghostty", "alacritty", "kitty"]
    private static let emailApps = ["mail", "outlook", "spark", "mimestream"]
    private static let documentApps = ["pages", "word", "notes", "notion", "obsidian", "textedit", "bear", "craft"]

    public static func category(appName: String?, bundleID: String?) -> AppToneCategory {
        let name = (appName ?? "").lowercased()
        let bundle = (bundleID ?? "").lowercased()
        func matches(_ list: [String]) -> Bool {
            list.contains { name.contains($0) || bundle.contains($0) }
        }
        if matches(chatApps) { return .chat }
        if matches(codeApps) { return .codeEditor }
        if matches(terminalApps) { return .terminal }
        if matches(emailApps) { return .email }
        if matches(documentApps) { return .document }
        return .generic
    }

    /// Tone rule appended to the system instruction. Nil for generic.
    public var toneInstruction: String? {
        switch self {
        case .chat:
            return "The user is writing a chat message: keep it conversational and natural, preserve emotion and casual phrasing."
        case .codeEditor:
            return "The user is writing in a code editor: be literal, preserve technical terms, identifiers, and symbols exactly; do not paraphrase code."
        case .terminal:
            return "The user is typing into a terminal: output the command or text verbatim with no embellishment."
        case .email:
            return "The user is writing an email: use clear, professional prose with proper sentences."
        case .document:
            return "The user is writing a document: use clear, well-structured prose."
        case .generic:
            return nil
        }
    }
}
