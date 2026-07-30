import ApplicationServices
import Cocoa
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "FocusedField")

/// Reads the text content of the currently focused UI element via the
/// Accessibility API. Best-effort: many apps (browsers, Electron) block
/// or partially support AX — every failure path returns nil quietly.
@MainActor
enum FocusedFieldReader {
    private static let maxLength = 2_000

    static func focusedFieldText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else { return nil }

        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXValueAttribute as CFString, &value
        ) == .success, let text = value as? String, !text.isEmpty else { return nil }

        // Keep the tail — dictation continues from the end of the field.
        return String(text.suffix(maxLength))
    }
}
