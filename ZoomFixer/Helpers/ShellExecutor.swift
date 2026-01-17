import Foundation

struct ShellResult {
    let command: String
    let output: String
    let exitCode: Int32
}

struct ShellExecutor {
    enum ShellError: LocalizedError {
        case commandFailed(command: String, code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case let .commandFailed(command, code, output):
                return "\(command) failed with code \(code): \(output)"
            }
        }
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
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let output = String(data: collected, encoding: .utf8) ?? ""
        lock.unlock()

        let renderedCommand = ([executable] + arguments).joined(separator: " ")
        return ShellResult(command: renderedCommand, output: output, exitCode: process.terminationStatus)
    }
}
