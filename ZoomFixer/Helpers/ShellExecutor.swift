import Foundation

struct ShellResult {
    let command: String
    let output: String
    let exitCode: Int32
}

/// Tracks child processes so a repair run can be cancelled while a command
/// is still executing. The flag is checked immediately after registration to
/// close the gap between a user tapping Cancel and a command being launched.
final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: Process] = [:]
    private var cancelRequested = false

    @discardableResult
    func register(_ process: Process) -> UUID {
        let id = UUID()
        lock.lock()
        active[id] = process
        lock.unlock()
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        active.removeValue(forKey: id)
        lock.unlock()
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    /// Called at the start of each run so a previous cancellation cannot
    /// terminate the next run's commands.
    func reset() {
        lock.lock()
        cancelRequested = false
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        cancelRequested = true
        let processes = Array(active.values)
        lock.unlock()

        for process in processes where process.isRunning {
            process.terminate()
        }
    }
}

struct ShellExecutor: Sendable {
    enum ShellError: LocalizedError {
        case commandFailed(command: String, code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case let .commandFailed(command, code, output):
                return "\(command) failed with code \(code): \(output)"
            }
        }
    }

    let registry: ProcessRegistry

    init(registry: ProcessRegistry = ProcessRegistry()) {
        self.registry = registry
    }

    func run(
        _ command: String,
        requireAdmin: Bool = false,
        allowFailure: Bool = false,
        onLine: ((String) -> Void)? = nil
    ) async throws -> ShellResult {
        let executable = requireAdmin ? "/usr/bin/osascript" : "/bin/bash"
        let arguments: [String] = requireAdmin
            ? ["-e", PrivilegedHelper.makeScript(for: command)]
            : ["-lc", command]

        let result = try await runProcess(executable: executable, arguments: arguments, onLine: onLine)

        if result.exitCode != 0 && !allowFailure {
            throw ShellError.commandFailed(command: command, code: result.exitCode, output: result.output)
        }

        return result
    }

    // MARK: - Internals

    private func runProcess(
        executable: String,
        arguments: [String],
        onLine: ((String) -> Void)?
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try self.runProcessSync(
                        executable: executable,
                        arguments: arguments,
                        onLine: onLine
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runProcessSync(
        executable: String,
        arguments: [String],
        onLine: ((String) -> Void)?
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var collected = Data()
        let lock = NSLock()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            lock.lock()
            collected.append(data)
            lock.unlock()

            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let cleaned = text.trimmingCharacters(in: .newlines)
                if !cleaned.isEmpty {
                    onLine?(cleaned)
                }
            }
        }

        try process.run()
        let token = registry.register(process)
        defer {
            registry.unregister(token)
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        // Cancellation may have arrived between the run-sequence check and
        // process launch; do not let that command keep mutating the system.
        if registry.isCancellationRequested && process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        lock.lock()
        let output = String(data: collected, encoding: .utf8) ?? ""
        lock.unlock()

        let renderedCommand = ([executable] + arguments).joined(separator: " ")
        return ShellResult(command: renderedCommand, output: output, exitCode: process.terminationStatus)
    }
}
