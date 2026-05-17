import Foundation
import Combine

/// Persists the last N run records to UserDefaults.
final class RunHistoryService: ObservableObject {
    @Published private(set) var records: [RunRecord] = []

    private let maxRecords = 10
    private let key = "zoomfixer.runHistory"

    init() { load() }

    func append(_ record: RunRecord) {
        var updated = [record] + records
        if updated.count > maxRecords { updated = Array(updated.prefix(maxRecords)) }
        records = updated
        save()
    }

    func clear() {
        records = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    func exportText(for record: RunRecord) -> String {
        let header = "ZoomFixer Run — \(record.date.formatted()) — \(record.outcome.uppercased())"
        let divider = String(repeating: "-", count: 60)
        let body = record.entries.map { e in
            let ts = DateFormatter.logTime.string(from: e.timestamp)
            return "[\(ts)][\(e.level)][\(e.category)] \(e.message)"
        }.joined(separator: "\n")
        return [header, divider, body].joined(separator: "\n")
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RunRecord].self, from: data)
        else { return }
        records = decoded
    }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
