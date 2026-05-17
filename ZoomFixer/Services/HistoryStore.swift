import Foundation

/// Persists the last N repair run records to disk using JSON.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let maxRecords = 10
    private let storeURL: URL

    @Published private(set) var records: [RunRecord] = []

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ZoomFixer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("history.json")
        load()
    }

    func append(_ record: RunRecord) {
        var updated = records
        updated.insert(record, at: 0)
        if updated.count > Self.maxRecords {
            updated = Array(updated.prefix(Self.maxRecords))
        }
        records = updated
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        records = (try? JSONDecoder().decode([RunRecord].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
