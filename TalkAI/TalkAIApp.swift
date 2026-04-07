import SwiftUI
import TalkAICore
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "App")

@main
struct TalkAIApp: App {
    @State private var appCoordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra("TalkAI", systemImage: appCoordinator.menuBarIcon) {
            MenuBarView(coordinator: appCoordinator)
        }

        Settings {
            SettingsView(coordinator: appCoordinator)
        }
    }
}

/// Central coordinator wiring hotkey → pipeline → paste.
@MainActor
@Observable
final class AppCoordinator {
    let pipeline = TranscriptionPipeline()
    let hotkeyManager = HotkeyManager()
    let pasteManager = PasteManager()
    let permissionManager = PermissionManager()
    let historyStore = HistoryStore()
    let overlayController = OverlayWindowController()

    private var recordingTask: Task<Void, Never>?

    var menuBarIcon: String {
        switch pipeline.state {
        case .recording:
            return "mic.fill"
        case .transcribing, .polishing:
            return "ellipsis.circle"
        default:
            return "mic"
        }
    }

    init() {
        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.handleHotkey()
            }
        }
        hotkeyManager.onEscPressed = { [weak self] in
            Task { @MainActor in
                await self?.handleCancel()
            }
        }
    }

    func handleHotkey() {
        switch pipeline.state {
        case .idle:
            overlayController.show(pipeline: pipeline)
            recordingTask = Task {
                await pipeline.start()
            }
        case .recording:
            recordingTask?.cancel()
            recordingTask = nil
            stopAndProcess()
        default:
            break
        }
    }

    func handleCancel() async {
        recordingTask?.cancel()
        recordingTask = nil
        await pipeline.cancel()
        overlayController.hide()
    }

    private func stopAndProcess() {
        // stop() is synchronous — it sets state and kicks off a Task internally
        pipeline.stop()

        // Watch for pipeline completion in a separate task
        Task {
            // Wait for the pipeline to reach a terminal state
            let result = await waitForPipelineResult()

            if let result {
                logger.error("Got result, polished: \(result.polishedText)")
                historyStore.add(result)

                // Write to clipboard and paste
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result.polishedText, forType: .string)
                logger.error("Clipboard set. Simulating paste...")

                // Small delay then simulate Cmd+V
                try? await Task.sleep(for: .milliseconds(150))
                pasteManager.simulatePaste()

                // Show "Pasted!" briefly
                try? await Task.sleep(for: .seconds(1.5))
            }

            overlayController.hide()
            pipeline.reset()
        }
    }

    /// Waits for pipeline to reach .done or .error state.
    private func waitForPipelineResult() async -> TranscriptionResult? {
        // Use withCheckedContinuation to avoid polling
        for _ in 0..<600 { // max 30 seconds (600 * 50ms)
            switch pipeline.state {
            case .done(let result):
                return result
            case .error(let msg):
                logger.error("Pipeline error: \(msg)")
                return nil
            case .idle:
                return nil
            default:
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        logger.error("Pipeline timed out")
        return nil
    }
}

struct MenuBarView: View {
    let coordinator: AppCoordinator

    var body: some View {
        switch coordinator.pipeline.state {
        case .idle:
            Button("Start Recording (Right ⌥)") {
                coordinator.handleHotkey()
            }
        case .recording:
            Button("Stop Recording (Right ⌥)") {
                coordinator.handleHotkey()
            }
        case .transcribing:
            Text("Transcribing...")
        case .polishing:
            Text("Polishing...")
        case .done:
            Text("Pasted!")
        case .error(let message):
            Text("Error: \(message)")
        case .cancelled:
            Text("Cancelled")
        }

        Divider()

        if !coordinator.pipeline.isLLMAvailable {
            Label("Apple Intelligence unavailable", systemImage: "exclamationmark.triangle")
        }

        SettingsLink {
            Text("Settings...")
        }

        Divider()

        Button("Quit TalkAI") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
