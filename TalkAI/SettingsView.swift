import SwiftUI
import TalkAICore

struct SettingsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralTab(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gear") }

            ModelTab(coordinator: coordinator)
                .tabItem { Label("Model", systemImage: "cpu") }

            HistoryTab(historyStore: coordinator.historyStore)
                .tabItem { Label("History", systemImage: "clock") }

            PermissionsTab(permissionManager: coordinator.permissionManager)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    let coordinator: AppCoordinator

    @AppStorage("sttEngine") private var sttEngine = "whisper"
    @AppStorage("whisperModel") private var whisperModel = WhisperModelOption.baseEn.rawValue
    @AppStorage("polishEnabled") private var polishEnabled = true
    @AppStorage("polishInstruction") private var polishInstruction = PolishService.defaultInstruction
    @AppStorage("selectedLanguage") private var selectedLanguage = "en-US"
    @State private var modelDownloadStatus: String?

    private let languages = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("zh-Hans", "Chinese (Simplified)")
    ]

    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Right ⌥ Option — press to start/stop recording")
                    .foregroundStyle(.secondary)
                Text("ESC — cancel recording")
                    .foregroundStyle(.secondary)
            }

            Section("Transcription Engine") {
                Picker("Engine", selection: $sttEngine) {
                    Text("Whisper (recommended)").tag("whisper")
                    Text("Apple Speech").tag("apple")
                }
                .onChange(of: sttEngine) { _, _ in coordinator.switchSTTEngine() }

                if sttEngine == "whisper" {
                    Picker("Whisper Model", selection: $whisperModel) {
                        ForEach(WhisperModelOption.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .onChange(of: whisperModel) { _, _ in
                        coordinator.switchSTTEngine()
                        downloadModel()
                    }

                    HStack {
                        Button("Download / Verify Model") { downloadModel() }
                        if let status = modelDownloadStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Models download once (from Hugging Face) and then run fully offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Language") {
                Picker("Transcription Language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    coordinator.pipeline.setLocale(Locale(identifier: newValue))
                    coordinator.switchSTTEngine()
                }
            }

            Section("AI Cleanup") {
                Toggle("Polish with AI", isOn: $polishEnabled)
                    .onChange(of: polishEnabled) { _, _ in coordinator.syncPolishSettings() }
                Text("When off, the raw transcription is pasted directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $polishInstruction)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .onChange(of: polishInstruction) { _, newValue in
                        coordinator.pipeline.polishInstruction = newValue
                    }

                Button("Reset to Default") {
                    polishInstruction = PolishService.defaultInstruction
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func downloadModel() {
        modelDownloadStatus = "Downloading…"
        let service = WhisperService(modelName: whisperModel, language: nil)
        Task {
            do {
                try await service.preloadModel()
                modelDownloadStatus = "Ready"
            } catch {
                modelDownloadStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Model Tab

private struct ModelTab: View {
    let coordinator: AppCoordinator

    @AppStorage("modelBackendType") private var backendType = ModelBackendType.apple.rawValue
    @AppStorage("useScreenshotContext") private var useScreenshotContext = false

    // Ollama settings
    @AppStorage("ollamaHost") private var ollamaHost = "localhost"
    @AppStorage("ollamaPort") private var ollamaPort = 11434
    @AppStorage("ollamaModel") private var ollamaModel = "qwen2.5:3b"
    @AppStorage("ollamaVision") private var ollamaVision = false

    // Cloud settings
    @AppStorage("cloudProvider") private var cloudProvider = CloudProvider.claude.rawValue
    @AppStorage("cloudModel") private var cloudModel = ""
    @State private var apiKey: String = ""
    @State private var connectionStatus: String?
    @State private var availableOllamaModels: [String] = []
    @State private var isFetchingModels = false

    var body: some View {
        Form {
            Section("Backend") {
                Picker("Model Backend", selection: $backendType) {
                    Text("Apple On-Device").tag(ModelBackendType.apple.rawValue)
                    Text("Ollama (Local)").tag(ModelBackendType.ollama.rawValue)
                    Text("Cloud API").tag(ModelBackendType.cloud.rawValue)
                }
                .onChange(of: backendType) { _, newValue in
                    coordinator.switchBackend(to: ModelBackendType(rawValue: newValue) ?? .apple)
                }

                Toggle("Use screen context", isOn: $useScreenshotContext)
                Text("Captures your active window, extracts on-screen text on-device, and uses it to correct names and technical terms — with every backend. Requires Screen Recording permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if backendType == ModelBackendType.ollama.rawValue {
                Section("Ollama Configuration") {
                    TextField("Host", text: $ollamaHost)
                    TextField("Port", value: $ollamaPort, format: .number)
                    HStack {
                        if availableOllamaModels.isEmpty {
                            TextField("Model Name", text: $ollamaModel)
                        } else {
                            Picker("Model", selection: $ollamaModel) {
                                ForEach(availableOllamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                        }
                        Button {
                            Task { await fetchOllamaModels() }
                        } label: {
                            if isFetchingModels {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isFetchingModels)
                    }

                    Toggle("Vision Model", isOn: $ollamaVision)
                    Text("Enable if your model supports images (e.g. llava, llama3.2-vision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Test Connection") {
                            Task {
                                connectionStatus = "Testing..."
                                let config = OllamaConfig(
                                    host: ollamaHost,
                                    port: ollamaPort,
                                    modelName: ollamaModel,
                                    isVisionModel: ollamaVision
                                )
                                let backend = OllamaPolishBackend(config: config)
                                let available = await backend.isAvailable
                                connectionStatus = available ? "Connected" : "Failed to connect"
                            }
                        }
                        if let status = connectionStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status == "Connected" ? .green : .red)
                        }
                    }
                }
                .task { await fetchOllamaModels() }
                .onChange(of: ollamaHost) { _, _ in
                    updateOllamaBackend()
                    Task { await fetchOllamaModels() }
                }
                .onChange(of: ollamaPort) { _, _ in
                    updateOllamaBackend()
                    Task { await fetchOllamaModels() }
                }
                .onChange(of: ollamaModel) { _, _ in updateOllamaBackend() }
                .onChange(of: ollamaVision) { _, _ in updateOllamaBackend() }
            }

            if backendType == ModelBackendType.cloud.rawValue {
                Section("Cloud API Configuration") {
                    Picker("Provider", selection: $cloudProvider) {
                        Text("Claude").tag(CloudProvider.claude.rawValue)
                        Text("OpenAI").tag(CloudProvider.openai.rawValue)
                    }
                    .onChange(of: cloudProvider) { _, newValue in
                        let provider = CloudProvider(rawValue: newValue) ?? .claude
                        if cloudModel.isEmpty || cloudModel == CloudProvider.claude.defaultModel || cloudModel == CloudProvider.openai.defaultModel {
                            cloudModel = provider.defaultModel
                        }
                        updateCloudBackend()
                    }

                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) { _, newValue in
                            let provider = CloudProvider(rawValue: cloudProvider) ?? .claude
                            KeychainHelper.save(key: "cloudApiKey_\(provider.rawValue)", value: newValue)
                            updateCloudBackend()
                        }

                    TextField("Model Name", text: $cloudModel)
                        .onChange(of: cloudModel) { _, _ in updateCloudBackend() }

                    HStack {
                        Button("Test Connection") {
                            Task {
                                connectionStatus = "Testing..."
                                let provider = CloudProvider(rawValue: cloudProvider) ?? .claude
                                let config = CloudConfig(provider: provider, apiKey: apiKey, modelName: cloudModel)
                                let backend = CloudPolishBackend(config: config)
                                let available = await backend.isAvailable
                                connectionStatus = available ? "Connected" : "Failed — check API key"
                            }
                        }
                        if let status = connectionStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status == "Connected" ? .green : .red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            let provider = CloudProvider(rawValue: cloudProvider) ?? .claude
            apiKey = KeychainHelper.load(key: "cloudApiKey_\(provider.rawValue)") ?? ""
            if cloudModel.isEmpty {
                cloudModel = provider.defaultModel
            }
        }
    }

    private func fetchOllamaModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }

        guard let url = URL(string: "http://\(ollamaHost):\(ollamaPort)/api/tags") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else { return }

            let names = models.compactMap { $0["name"] as? String }.sorted()
            await MainActor.run {
                if ollamaModel.isEmpty, let first = names.first {
                    ollamaModel = first
                }
                // Keep the configured model selectable even if the daemon
                // hasn't reported it yet (e.g. still downloading) — never
                // silently switch the user off a model they configured.
                availableOllamaModels = names.contains(ollamaModel) || ollamaModel.isEmpty
                    ? names
                    : (names + [ollamaModel]).sorted()
            }
        } catch {
            // Fetch failed — keep text field fallback
        }
    }

    private func updateOllamaBackend() {
        let config = OllamaConfig(
            host: ollamaHost,
            port: ollamaPort,
            modelName: ollamaModel,
            isVisionModel: ollamaVision
        )
        coordinator.pipeline.polishService.backend = OllamaPolishBackend(config: config)
    }

    private func updateCloudBackend() {
        let provider = CloudProvider(rawValue: cloudProvider) ?? .claude
        let config = CloudConfig(provider: provider, apiKey: apiKey, modelName: cloudModel)
        coordinator.pipeline.polishService.backend = CloudPolishBackend(config: config)
    }
}

// MARK: - History Tab

private struct HistoryTab: View {
    let historyStore: HistoryStore

    var body: some View {
        VStack {
            if historyStore.items.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("Transcriptions will appear here after you use TalkAI.")
                )
            } else {
                List(historyStore.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.polishedText)
                            .lineLimit(2)
                        Text(item.date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Copy Polished Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.polishedText, forType: .string)
                        }
                        Button("Copy Raw Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.rawText, forType: .string)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Clear History") {
                        historyStore.clear()
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Permissions Tab

private struct PermissionsTab: View {
    let permissionManager: PermissionManager

    var body: some View {
        Form {
            PermissionRow(
                title: "Microphone",
                description: "Required for voice capture",
                granted: permissionManager.microphoneGranted,
                action: {
                    Task { await permissionManager.requestMicrophone() }
                },
                actionLabel: "Request Access"
            )

            PermissionRow(
                title: "Accessibility",
                description: "Required for global hotkey and paste simulation",
                granted: permissionManager.accessibilityGranted,
                action: { permissionManager.openAccessibilitySettings() },
                actionLabel: "Open Settings"
            )

            PermissionRow(
                title: "Apple Intelligence",
                description: "Only needed for the Apple On-Device polish backend",
                granted: permissionManager.appleIntelligenceAvailable,
                action: { permissionManager.openAppleIntelligenceSettings() },
                actionLabel: "Open Settings"
            )

            PermissionRow(
                title: "Screen Recording",
                description: "Optional — enables screen context for AI polishing",
                granted: permissionManager.screenRecordingGranted,
                action: { permissionManager.openScreenRecordingSettings() },
                actionLabel: "Open Settings"
            )
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            permissionManager.refresh()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let action: () -> Void
    let actionLabel: String

    var body: some View {
        LabeledContent {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionLabel, action: action)
            }
        } label: {
            VStack(alignment: .leading) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
