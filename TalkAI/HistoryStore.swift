import Foundation
import TalkAICore

/// Persists recent transcription results locally.
@MainActor
@Observable
final class HistoryStore {
    private static let storageKey = "TalkAI.history"
    private static let maxItems = 50

    var items: [TranscriptionResult] = []

    init() {
        load()
    }

    func add(_ result: TranscriptionResult) {
        items.insert(result, at: 0)
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
        }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([TranscriptionResult].self, from: data) else {
            return
        }
        items = decoded
    }
}
