import Foundation

/// Categories used for grouping steps in the UI and structured report.
enum RepairCategory: String, CaseIterable {
    case systemDiagnostic = "System Diagnostic"
    case networkDiagnostic = "Network Diagnostic"
    case macSpoofing = "MAC Address"
    case zoomRepair = "Zoom Repair"
    case postInstall = "Post-Install"
}

/// Severity levels for structured log entries.
enum LogLevel: String {
    case info  = "info"
    case warn  = "warn"
    case error = "error"
    case ok    = "ok"

    var prefix: String {
        switch self {
        case .info:  return "[info]"
        case .warn:  return "[warn]"
        case .error: return "[error]"
        case .ok:    return "[ok]"
        }
    }
}

/// A single structured log entry.
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    var formatted: String {
        let ts = DateFormatter.logTime.string(from: timestamp)
        return "[\(ts)] \(level.prefix)[\(category)] \(message)"
    }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Step outcome recorded after each step runs.
enum StepOutcome {
    case pending
    case running
    case success
    case warning(String)
    case failed(String)

    var symbol: String {
        switch self {
        case .pending:      return "⏳"
        case .running:      return "🔄"
        case .success:      return "✅"
        case .warning:      return "⚠️"
        case .failed:       return "❌"
        }
    }
}

/// A repair/diagnostic step described by metadata.
struct RepairStep {
    let id: UUID
    let title: String
    let category: RepairCategory
    let isDestructive: Bool
    var isEnabled: Bool
    let action: () async throws -> Void

    init(
        title: String,
        category: RepairCategory,
        isDestructive: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () async throws -> Void
    ) {
        self.id = UUID()
        self.title = title
        self.category = category
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// A persisted record of a past run.
struct RunRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let outcome: String  // "success" | "warning" | "failed"
    let entries: [PersistedEntry]

    struct PersistedEntry: Codable {
        let timestamp: Date
        let level: String
        let category: String
        let message: String
    }

    static func from(entries: [LogEntry], outcome: String) -> RunRecord {
        RunRecord(
            id: UUID(),
            date: Date(),
            outcome: outcome,
            entries: entries.map {
                PersistedEntry(timestamp: $0.timestamp, level: $0.level.rawValue,
                               category: $0.category, message: $0.message)
            }
        )
    }
}
