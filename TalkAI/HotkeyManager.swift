import Cocoa
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Hotkey")

/// Manages global hotkey capture using CGEvent taps.
@MainActor
final class HotkeyManager {
    var onHotkeyPressed: (@Sendable () -> Void)?
    var onEscPressed: (@Sendable () -> Void)?

    /// Whether the event tap is active and receiving events.
    private(set) var isActive = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The key code for Right Option (kVK_RightOption = 0x3D = 61).
    private let hotkeyCode: CGKeyCode = 61

    init() {
        let trusted = AXIsProcessTrusted()
        logger.notice("Accessibility trusted: \(trusted)")

        if !trusted {
            // Prompt user to grant accessibility
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let options = [key: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            logger.warning("Requested accessibility permission. Event tap will not work until granted.")
        }

        setupEventTap()
    }

    /// Tear down existing tap and re-create it. Call after accessibility is granted.
    func retrySetup() {
        guard !isActive else { return }
        removeEventTap()
        setupEventTap()
    }

    private func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        // Store callbacks in local vars to avoid capturing self in the C callback
        let onHotkey = { [weak self] in
            DispatchQueue.main.async {
                logger.notice("Hotkey pressed!")
                self?.onHotkeyPressed?()
            }
        }
        let onEsc = { [weak self] in
            DispatchQueue.main.async {
                logger.notice("ESC pressed!")
                self?.onEscPressed?()
            }
        }
        let hotkeyCode = self.hotkeyCode

        let context = HotkeyContext(
            hotkeyCode: hotkeyCode,
            onHotkey: onHotkey,
            onEsc: onEsc
        )
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: contextPtr
        ) else {
            Unmanaged<HotkeyContext>.fromOpaque(contextPtr).release()
            isActive = false
            logger.error("Failed to create event tap. Accessibility permission required.")
            return
        }

        logger.notice("Event tap created successfully")
        context.eventTap = tap
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isActive = true
            logger.notice("Event tap enabled and running")
        }
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isActive = false
    }
}

// MARK: - C callback context

private final class HotkeyContext {
    let hotkeyCode: CGKeyCode
    let onHotkey: () -> Void
    let onEsc: () -> Void
    var eventTap: CFMachPort?

    init(hotkeyCode: CGKeyCode, onHotkey: @escaping () -> Void, onEsc: @escaping () -> Void) {
        self.hotkeyCode = hotkeyCode
        self.onHotkey = onHotkey
        self.onEsc = onEsc
    }
}

// Free function for the C callback
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let context = Unmanaged<HotkeyContext>.fromOpaque(refcon).takeUnretainedValue()

    // Handle ESC key
    if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
        context.onEsc()
        return nil
    }

    // Handle Right Option key (flagsChanged event)
    if type == .flagsChanged {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if keyCode == Int64(context.hotkeyCode) && flags.contains(.maskAlternate) {
            context.onHotkey()
            return nil
        }
    }

    // Re-enable tap if disabled by system
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = context.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passRetained(event)
}
