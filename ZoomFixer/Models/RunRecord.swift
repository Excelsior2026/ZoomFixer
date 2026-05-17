import Foundation

/// Persisted record of a single ZoomFixer run stored in history.
struct RunRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let success: Bool
    let hadWarnings: Bool
    let entries: [LogEntry]

    init(date: Date = Date(), success: Bool, hadWarnings: Bool, entries: [LogEntry]) {
        self.id = UUID()
        self.date = date
        self.success = success
        self.hadWarnings = hadWarnings
        self.entries = entries
    }

    var summary: String {
        if success && !hadWarnings { return "✅ Repaired" }
        if success && hadWarnings  { return "⚠️ Repaired with warnings" }
        return "❌ Failed"
    }
}
