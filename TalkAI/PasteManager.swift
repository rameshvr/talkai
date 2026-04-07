import Cocoa
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Paste")

/// Handles clipboard write and simulated Cmd+V paste.
@MainActor
final class PasteManager {

    /// Write text to clipboard and simulate Cmd+V.
    func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general

        // Write polished text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.error("Clipboard set with polished text (\(text.count) chars)")

        // Delay to ensure clipboard is ready
        try? await Task.sleep(for: .milliseconds(100))

        // Simulate Cmd+V (requires Accessibility permission)
        let pasted = simulatePaste()
        logger.error("Paste simulation result: \(pasted)")

        // Text stays in clipboard so user can manually Cmd+V if auto-paste fails
    }

    @discardableResult
    func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code for 'V' is 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            logger.error("Failed to create CGEvent for paste")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
