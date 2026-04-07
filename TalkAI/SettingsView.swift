import SwiftUI
import TalkAICore

struct SettingsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralTab(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gear") }

            HistoryTab(historyStore: coordinator.historyStore)
                .tabItem { Label("History", systemImage: "clock") }

            PermissionsTab(permissionManager: coordinator.permissionManager)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    let coordinator: AppCoordinator

    @AppStorage("polishInstruction") private var polishInstruction = PolishService.defaultInstruction
    @AppStorage("selectedLanguage") private var selectedLanguage = "en-US"

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

            Section("Language") {
                Picker("Transcription Language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    coordinator.pipeline.setLocale(Locale(identifier: newValue))
                }
            }

            Section("AI Cleanup Prompt") {
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
                description: "Required for AI text cleanup",
                granted: permissionManager.appleIntelligenceAvailable,
                action: { permissionManager.openAppleIntelligenceSettings() },
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
