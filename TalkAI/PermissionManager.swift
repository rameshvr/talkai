import AVFoundation
import Cocoa
import FoundationModels

/// Checks and requests required system permissions.
@MainActor
@Observable
final class PermissionManager {
    var microphoneGranted = false
    var accessibilityGranted = false
    var appleIntelligenceAvailable = false

    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted && appleIntelligenceAvailable
    }

    init() {
        refresh()
    }

    func refresh() {
        checkMicrophone()
        checkAccessibility()
        checkAppleIntelligence()
    }

    // MARK: - Microphone

    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        default:
            microphoneGranted = false
        }
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneGranted = granted
    }

    // MARK: - Accessibility

    func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Apple Intelligence

    func checkAppleIntelligence() {
        appleIntelligenceAvailable = SystemLanguageModel.default.isAvailable
    }

    func openAppleIntelligenceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.appleintellligence") {
            NSWorkspace.shared.open(url)
        }
    }
}
