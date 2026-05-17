import Foundation

/// Severity level for structured log entries.
enum LogLevel: String, Codable {
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"
}

/// A single structured log entry.
struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    init(level: LogLevel = .info, category: String = "general", message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
    }

    var formatted: String {
        let t = DateFormatter.logTime.string(from: timestamp)
        return "[\(t)][\(level.rawValue)][\(category)] \(message)"
    }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Category grouping for repair steps.
enum RepairCategory: String, CaseIterable {
    case diagnostic  = "Diagnostics"
    case network     = "Network"
    case system      = "System"
    case zoom        = "Zoom"
    case mac         = "MAC Address"
}

/// Protocol every repair/diagnostic step conforms to.
protocol RepairStep {
    var id: String { get }
    var title: String { get }
    var category: RepairCategory { get }
    /// If true, the step modifies system state (shows a warning badge in UI).
    var isDestructive: Bool { get }
    /// If false, the step is skipped during a scan-only run.
    var runInScanMode: Bool { get }
    /// Perform the step. Append entries via the provided logger.
    func run(logger: @escaping (LogEntry) -> Void) async throws
}

/// Concrete wrapper so plain closures can be used as steps.
struct AnyRepairStep: RepairStep {
    let id: String
    let title: String
    let category: RepairCategory
    let isDestructive: Bool
    let runInScanMode: Bool
    private let action: (@escaping (LogEntry) -> Void) async throws -> Void

    init(
        id: String,
        title: String,
        category: RepairCategory,
        isDestructive: Bool = false,
        runInScanMode: Bool = true,
        action: @escaping (@escaping (LogEntry) -> Void) async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.isDestructive = isDestructive
        self.runInScanMode = runInScanMode
        self.action = action
    }

    func run(logger: @escaping (LogEntry) -> Void) async throws {
        try await action(logger)
    }
}
