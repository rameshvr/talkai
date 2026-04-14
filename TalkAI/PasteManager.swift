import Cocoa
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Paste")

/// Saved pasteboard item: an array of (type, data) pairs per item.
private struct SavedPasteboardItem {
    let representations: [(NSPasteboard.PasteboardType, Data)]
}

/// Handles clipboard write and simulated Cmd+V paste.
@MainActor
final class PasteManager {

    /// Write text to clipboard, simulate Cmd+V, then restore original clipboard.
    func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems = savePasteboard(pasteboard)

        // Write polished text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Clipboard set with polished text (\(text.count) chars)")

        // Delay to ensure clipboard is ready
        try? await Task.sleep(for: .milliseconds(100))

        // Simulate Cmd+V (requires Accessibility permission)
        let pasted = simulatePaste()
        logger.info("Paste simulation result: \(pasted)")

        // Wait for the target app to read the clipboard
        try? await Task.sleep(for: .milliseconds(200))

        // Restore original clipboard contents
        restorePasteboard(pasteboard, items: savedItems)
        logger.info("Clipboard restored")
    }

    // MARK: - Clipboard save/restore

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [SavedPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let representations = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return SavedPasteboardItem(representations: representations)
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [SavedPasteboardItem]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let pasteboardItems = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
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
