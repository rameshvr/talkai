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
    private var contextTask: Task<Void, Never>?
    private var permissionCheckTask: Task<Void, Never>?
    private var isStopping = false

    /// Error message from the most recent polish failure (raw text was pasted).
    var lastPolishError: String?

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
        switchSTTEngine()
        syncPolishSettings()

        let preferredBackend = currentBackendType
        switchBackend(to: preferredBackend)
        if preferredBackend == .apple && !pipeline.isLLMAvailable {
            // Runtime-only fallback — the user's stored "modelBackendType" preference
            // is left untouched so Apple is retried automatically once available.
            logger.notice("Apple Intelligence unavailable at launch, falling back to Ollama for this session")
            switchBackend(to: .ollama)
        }
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

    var currentBackendType: ModelBackendType {
        ModelBackendType(rawValue: UserDefaults.standard.string(forKey: "modelBackendType") ?? "") ?? .apple
    }

    /// Rebuild the STT backend from settings. Whisper is the default.
    func switchSTTEngine() {
        let engine = UserDefaults.standard.string(forKey: "sttEngine") ?? "whisper"
        if engine == "apple" {
            let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"
            let apple = SpeechService(locale: Locale(identifier: lang))
            pipeline.setSTTBackend(apple)
        } else {
            let model = UserDefaults.standard.string(forKey: "whisperModel") ?? WhisperModelOption.baseEn.rawValue
            let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"
            let whisperLang = String(lang.prefix(2))  // "en-US" → "en"
            pipeline.setSTTBackend(WhisperService(modelName: model, language: whisperLang))
        }
        logger.notice("STT engine: \(engine)")
    }

    /// Sync polish enablement from settings.
    func syncPolishSettings() {
        pipeline.polishEnabled = UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
    }

    func switchBackend(to type: ModelBackendType) {
        switch type {
        case .apple:
            pipeline.polishService.backend = ApplePolishBackend()
        case .ollama:
            let config = OllamaConfig(
                host: UserDefaults.standard.string(forKey: "ollamaHost") ?? "localhost",
                port: UserDefaults.standard.integer(forKey: "ollamaPort").nonZero ?? 11434,
                modelName: UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen2.5:3b",
                isVisionModel: UserDefaults.standard.bool(forKey: "ollamaVision")
            )
            let ollamaBackend = OllamaPolishBackend(config: config)
            pipeline.polishService.backend = ollamaBackend
            Task { await ollamaBackend.warmUp() }
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
            // Capture context BEFORE showing the overlay so we read the
            // user's actual working window, not ours.
            let metadata = screenshotService.activeAppMetadata()
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let fieldText = FocusedFieldReader.focusedFieldText()
            let wantsScreenContext = useScreenshotContext
            let backendSupportsVision = pipeline.polishService.backend.supportsVision

            // Metadata-only context is available immediately.
            pipeline.context = PolishContext(
                appName: metadata.appName,
                windowTitle: metadata.windowTitle,
                focusedFieldText: fieldText,
                appBundleID: bundleID
            )
            pipeline.hotwordPrompt = nil

            if wantsScreenContext {
                // Screenshot must happen before recording begins;
                // OCR runs while the user is speaking.
                contextTask = Task { [weak self] in
                    guard let self else { return }
                    let screenshot = await screenshotService.captureActiveWindow()
                    guard !Task.isCancelled else { return }

                    var screenText: String?
                    if let screenshot {
                        screenText = await OCRService.recognizeText(in: screenshot)
                    }
                    guard !Task.isCancelled else { return }

                    let hotwords = screenText.map { HotwordExtractor.extract(from: $0) } ?? []
                    guard !Task.isCancelled else { return }

                    // A cancelled task may already be superseded by a new recording —
                    // never let a stale capture overwrite the current one's context.
                    pipeline.context = PolishContext(
                        appName: metadata.appName,
                        windowTitle: metadata.windowTitle,
                        screenshot: backendSupportsVision ? screenshot : nil,
                        screenText: screenText,
                        focusedFieldText: fieldText,
                        appBundleID: bundleID
                    )
                    pipeline.hotwordPrompt = HotwordExtractor.prompt(from: hotwords)
                }
            }

            overlayController.show(pipeline: pipeline)
            recordingTask = Task {
                await pipeline.start()
            }
        case .recording:
            guard !isStopping else { break }
            isStopping = true
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
        contextTask?.cancel()
        contextTask = nil
        isStopping = false
        await pipeline.cancel()
        overlayController.hide()
    }

    private func stopAndProcess() {
        Task {
            // Ensure OCR/hotwords finished before transcription consumes them.
            await contextTask?.value
            contextTask = nil
            pipeline.stop()

            let result = await waitForPipelineResult()

            if let result {
                logger.info("Got result, polished: \(result.polishedText)")
                lastPolishError = result.polishError
                historyStore.add(result)

                await pasteManager.paste(result.polishedText)
                try? await Task.sleep(for: .seconds(1.5))
            } else if case .error = pipeline.state {
                // Dwell so the user can actually read the error before it disappears.
                try? await Task.sleep(for: .seconds(1.5))
            }

            overlayController.hide()
            pipeline.reset()
            isStopping = false
        }
    }

    /// Waits for pipeline to reach .done or .error state.
    private func waitForPipelineResult() async -> TranscriptionResult? {
        let iterations = Int(PipelineTiming.resultWaitTimeout / 0.05)
        for _ in 0..<iterations { // exceeds backend requestTimeout — late results are never dropped
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

        if let polishError = coordinator.lastPolishError {
            Label("Last AI cleanup failed — raw text was pasted", systemImage: "exclamationmark.circle")
            Text(polishError)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if coordinator.currentBackendType == .apple && !coordinator.pipeline.isLLMAvailable {
            Label("Apple Intelligence unavailable — switch Model backend in Settings", systemImage: "exclamationmark.triangle")
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
