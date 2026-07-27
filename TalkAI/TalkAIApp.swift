import SwiftUI
import TalkAICore
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "App")

private extension Int {
    /// Returns self if non-zero, otherwise nil. Useful for UserDefaults int fallbacks.
    var nonZero: Int? { self == 0 ? nil : self }
}

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
    let screenshotService = ScreenshotService()

    private var recordingTask: Task<Void, Never>?
    private var permissionCheckTask: Task<Void, Never>?

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
        startPermissionMonitor()
    }

    /// Periodically checks accessibility permission and retries event tap setup when granted.
    private func startPermissionMonitor() {
        permissionCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                permissionManager.checkAccessibility()
                // If permission was just granted and event tap isn't active, retry
                if permissionManager.accessibilityGranted && !hotkeyManager.isActive {
                    hotkeyManager.retrySetup()
                    if hotkeyManager.isActive {
                        logger.notice("Event tap established after permission grant")
                    }
                }
                // Stop polling once everything is working
                if permissionManager.accessibilityGranted && hotkeyManager.isActive {
                    return
                }
            }
        }
    }

    var useScreenshotContext: Bool {
        UserDefaults.standard.bool(forKey: "useScreenshotContext")
    }

    func switchBackend(to type: ModelBackendType) {
        switch type {
        case .apple:
            pipeline.polishService.backend = ApplePolishBackend()
        case .ollama:
            let config = OllamaConfig(
                host: UserDefaults.standard.string(forKey: "ollamaHost") ?? "localhost",
                port: UserDefaults.standard.integer(forKey: "ollamaPort").nonZero ?? 11434,
                modelName: UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2",
                isVisionModel: UserDefaults.standard.bool(forKey: "ollamaVision")
            )
            pipeline.polishService.backend = OllamaPolishBackend(config: config)
        case .cloud:
            let providerRaw = UserDefaults.standard.string(forKey: "cloudProvider") ?? CloudProvider.claude.rawValue
            let provider = CloudProvider(rawValue: providerRaw) ?? .claude
            let apiKey = KeychainHelper.load(key: "cloudApiKey_\(provider.rawValue)") ?? ""
            let model = UserDefaults.standard.string(forKey: "cloudModel") ?? provider.defaultModel
            let config = CloudConfig(provider: provider, apiKey: apiKey, modelName: model)
            pipeline.polishService.backend = CloudPolishBackend(config: config)
        }
        logger.notice("Switched backend to: \(type.displayName)")
    }

    func handleHotkey() {
        if !permissionManager.accessibilityGranted {
            permissionManager.openAccessibilitySettings()
            return
        }

        switch pipeline.state {
        case .idle:
            // Capture context BEFORE showing overlay so we get the user's actual working window
            let metadata = screenshotService.activeAppMetadata()

            if useScreenshotContext && pipeline.polishService.backend.supportsVision {
                // Capture screenshot async, then start recording
                Task {
                    let screenshot = await screenshotService.captureActiveWindow()
                    pipeline.context = PolishContext(
                        appName: metadata.appName,
                        windowTitle: metadata.windowTitle,
                        screenshot: screenshot
                    )
                    overlayController.show(pipeline: pipeline)
                    recordingTask = Task {
                        await pipeline.start()
                    }
                }
            } else {
                pipeline.context = PolishContext(
                    appName: metadata.appName,
                    windowTitle: metadata.windowTitle
                )
                overlayController.show(pipeline: pipeline)
                recordingTask = Task {
                    await pipeline.start()
                }
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
                logger.info("Got result, polished: \(result.polishedText)")
                historyStore.add(result)

                await pasteManager.paste(result.polishedText)

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
        if !coordinator.permissionManager.accessibilityGranted {
            Label("Accessibility Required", systemImage: "exclamationmark.triangle")
            Text("Hotkey and paste won't work without Accessibility permission.")
                .font(.caption)
            Button("Grant Accessibility Access") {
                coordinator.permissionManager.openAccessibilitySettings()
            }
        } else {
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
