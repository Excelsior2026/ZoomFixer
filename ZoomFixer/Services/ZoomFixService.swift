import Foundation
import Combine
import AppKit

final class ZoomFixService: ObservableObject {
    enum StatusKind {
        case idle
        case running
        case success
        case warning
        case failed
    }

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var statusKind: StatusKind = .idle
    @Published private(set) var logs: [String] = []
    @Published private(set) var progress: Double? = nil
    @Published private(set) var progressLabel: String = "Ready"
    @Published private(set) var dockerStatus: String = "Docker sandbox not running"
    @Published private(set) var isLaunchingDocker = false
    @Published private(set) var isInstallingDocker = false
    @Published private(set) var isAutoDockerFlow = false

    private let shell = ShellExecutor()
    private let downloader = DownloadService()
    private var discoveredInstallations: [URL] = []
    private var adminInstallationPaths: [URL] = []
    private var installerURL: URL?
    private var hadErrors = false

    func startFix() {
        guard !isRunning else { return }

        Task {
            await prepareForRun()
            await runSequence()
        }
    }

    // MARK: - Sequence

    private func runSequence() async {
        let steps: [(String, () async throws -> Void)] = [
            ("Kill Zoom processes", killZoomProcesses),
            ("Clear Zoom cache", clearZoomCache),
            ("Clear Zoom preferences", clearPreferences),
            ("Remove Zoom logs", removeLogs),
            ("Find duplicate installations", findDuplicates),
            ("Remove all Zoom installations", removeInstallations),
            ("Download latest Zoom", downloadLatest),
            ("Install & repair with admin tasks", performPrivilegedInstall),
            ("Verify installation", verifyInstallation)
        ]

        for (title, action) in steps {
            await updateStatus(message: title, kind: .running)
            await log("== \(title) ==")

            do {
                try await action()
                await log("[ok] \(title)")
            } catch {
                hadErrors = true
                await log("[error] \(title): \(error.localizedDescription)")
            }
        }

        await finish()
    }

    // MARK: - Docker sandbox

    func autoPrepareAndLaunchDockerSandbox() {
        guard !isLaunchingDocker, !isInstallingDocker else { return }

        Task {
            await setDockerStatus("Preparing Docker automatically...", running: true, installing: true, auto: true)
            do {
                if try await !dockerCliPresent() {
                    await log("[docker] Docker not found, attempting Homebrew install...")
                    try await installDockerWithBrew()
                }

                try await startDockerDaemonIfNeeded()
                try await launchSandboxFlow()
                await openSandboxUrl()
                await setDockerStatus("Sandbox running. Open http://localhost:6080/vnc.html (noVNC) or VNC to localhost:5901.", running: false, installing: false, auto: false)
            } catch {
                await log("[docker] \(error.localizedDescription)")
                await setDockerStatus("Auto-setup failed: \(error.localizedDescription)", running: false, installing: false, auto: false)
            }
        }
    }

    func launchDockerSandbox() {
        guard !isLaunchingDocker else { return }

        Task {
            await setDockerStatus("Preparing Docker sandbox...", running: true)

            do {
                try await launchSandboxFlow()
                await openSandboxUrl()
                await setDockerStatus("Sandbox running. Open http://localhost:6080/vnc.html (noVNC) or VNC to localhost:5901.", running: false)
            } catch {
                await log("[docker] \(error.localizedDescription)")
                await setDockerStatus("Docker sandbox failed: \(error.localizedDescription)", running: false)
            }
        }
    }

    func checkDockerAvailability() {
        guard !isLaunchingDocker else { return }
        Task {
            do {
                try await ensureDockerAvailable()
                await setDockerStatus("Docker is available. You can launch the sandbox.", running: false)
            } catch {
                await log("[docker] \(error.localizedDescription)")
                await setDockerStatus("Docker check failed: \(error.localizedDescription)", running: false)
            }
        }
    }

    func openDockerDownloadPage() {
        guard let url = URL(string: "https://www.docker.com/products/docker-desktop/") else { return }
        NSWorkspace.shared.open(url)
        Task { @MainActor in
            dockerStatus = "Opening Docker Desktop download page..."
        }
    }

    func installDockerViaHomebrew() {
        guard !isInstallingDocker, !isLaunchingDocker else { return }
        Task {
            await setDockerStatus("Installing Docker Desktop via Homebrew...", running: true, installing: true)
            do {
                try await installDockerWithBrew()
                await setDockerStatus("Docker Desktop installed. Launch it, wait for daemon to start, then re-check.", running: false, installing: false)
            } catch {
                await log("[docker-install] \(error.localizedDescription)")
                await setDockerStatus("Docker install via Homebrew failed: \(error.localizedDescription)", running: false, installing: false)
            }
        }
    }

    private func launchSandboxFlow() async throws {
        try await ensureDockerAvailable()
        let context = try makeDockerContext()
        defer { try? FileManager.default.removeItem(at: context) }

        try await buildDockerImage(at: context)
        try await runDockerContainer()
    }

    private func ensureDockerAvailable() async throws {
        let hasCli = try await shell.run("command -v docker", allowFailure: true)
        guard hasCli.exitCode == 0 else {
            throw DockerAvailabilityError("Docker CLI not found. Install Docker Desktop and ensure `docker` is on your PATH.")
        }

        let info = try await shell.run("docker info --format '{{.ServerVersion}}'", allowFailure: true)
        guard info.exitCode == 0 else {
            let detail = info.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerAvailabilityError("Docker daemon unavailable. Start Docker Desktop and retry. Details: \(detail.isEmpty ? "docker info failed" : detail)")
        }

        await log("[docker] Docker daemon is running")
    }

    private func dockerCliPresent() async throws -> Bool {
        let hasCli = try await shell.run("command -v docker", allowFailure: true)
        return hasCli.exitCode == 0
    }

    private func brewPresent() async throws -> Bool {
        let brewCheck = try await shell.run("command -v brew", allowFailure: true)
        return brewCheck.exitCode == 0
    }

    private func installDockerWithBrew() async throws {
        guard try await brewPresent() else {
            throw DockerAvailabilityError("Homebrew not installed. Install Homebrew or use the Docker Desktop download.")
        }

        try await shell.run("brew install --cask docker", allowFailure: false, onLine: { [weak self] line in
            Task { [weak self] in await self?.log("[docker-install] \(line)") }
        })
        await log("[docker-install] Docker Desktop installed via Homebrew")
    }

    private func startDockerDaemonIfNeeded() async throws {
        let info = try await shell.run("docker info --format '{{.ServerVersion}}'", allowFailure: true)
        if info.exitCode == 0 {
            await log("[docker] Docker daemon already running")
            return
        }

        await log("[docker] Starting Docker Desktop...")
        _ = try? await shell.run("open -ga Docker", allowFailure: true)

        let attempts = 12
        for attempt in 1...attempts {
            let check = try await shell.run("docker info --format '{{.ServerVersion}}'", allowFailure: true)
            if check.exitCode == 0 {
                await log("[docker] Docker daemon is now running")
                return
            }
            let seconds = 5
            await log("[docker] Waiting for Docker daemon (\(attempt)/\(attempts))...")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        throw DockerAvailabilityError("Docker daemon did not start. Please open Docker Desktop and retry.")
    }

    @MainActor
    private func openSandboxUrl() {
        if let url = URL(string: "http://localhost:6080/vnc.html") {
            NSWorkspace.shared.open(url)
        }
    }

    private func makeDockerContext() throws -> URL {
        let temp = FileManager.default.temporaryDirectory
        let dir = temp.appendingPathComponent("zoomfixer-docker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dockerfile = dir.appendingPathComponent("Dockerfile")
        let entrypoint = dir.appendingPathComponent("entrypoint.sh")
        try dockerfileContents.write(to: dockerfile, atomically: true, encoding: .utf8)
        try entrypointScript.write(to: entrypoint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)

        return dir
    }

    private func buildDockerImage(at context: URL) async throws {
        let command = "docker build -t zoomfixer-sandbox \"\(context.path)\""
        try await shell.run(command, allowFailure: false, onLine: { [weak self] line in
            Task { [weak self] in await self?.log("[docker] \(line)") }
        })
        await log("[docker] Image ready: zoomfixer-sandbox")
    }

    private func runDockerContainer() async throws {
        let command = """
        docker ps -a --filter name=zoomfixer-sandbox --format '{{.Names}}' | grep -q zoomfixer-sandbox && docker rm -f zoomfixer-sandbox || true
        docker run -d --rm --name zoomfixer-sandbox -p 5901:5901 -p 6080:6080 -v zoomfixer_home:/home/zoomuser zoomfixer-sandbox
        """
        let result = try await shell.run(command, onLine: { [weak self] line in
            Task { [weak self] in await self?.log("[docker] \(line)") }
        })

        if let containerID = result.output.split(separator: "\n").last, !containerID.isEmpty {
            await log("[docker] Container id: \(containerID)")
        }
    }

    private var dockerfileContents: String {
        """
        FROM ubuntu:22.04

        ENV DEBIAN_FRONTEND=noninteractive \\
            USER=zoomuser \\
            HOME=/home/zoomuser \\
            DISPLAY=:0

        RUN apt-get update && apt-get install -y --no-install-recommends \\
            curl ca-certificates wget gnupg2 \\
            libxcb-xtest0 libxcb-shape0 libegl1 libglu1-mesa libsm6 libxv1 libxrender1 libxi6 libxrandr2 libxcursor1 libxss1 libasound2 libpulse0 libnss3 libxcomposite1 xdg-utils dbus-x11 xauth \\
            xvfb fluxbox x11vnc novnc websockify pulseaudio \\
            && rm -rf /var/lib/apt/lists/*

        RUN curl -L https://zoom.us/client/latest/zoom_amd64.deb -o /tmp/zoom.deb && \\
            apt-get update && apt-get install -y /tmp/zoom.deb || (apt-get install -f -y && apt-get install -y /tmp/zoom.deb)

        RUN useradd -ms /bin/bash $USER
        USER root
        WORKDIR $HOME

        COPY entrypoint.sh /usr/local/bin/entrypoint.sh
        RUN chmod +x /usr/local/bin/entrypoint.sh

        EXPOSE 5901 6080

        ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
        """
    }

    private var entrypointScript: String {
        """
        #!/usr/bin/env bash
        set -e
        export DISPLAY=:0

        pulseaudio -D --exit-idle-time=-1 --log-target=syslog || true
        Xvfb :0 -screen 0 1280x800x24 &
        sleep 2
        fluxbox &
        x11vnc -display :0 -forever -shared -rfbport 5901 -nopw &
        /usr/share/novnc/utils/launch.sh --vnc localhost:5901 --listen 6080 --forever &

        su - zoomuser -c "/usr/bin/zoom" &
        wait -n
        """
    }

    // MARK: - Steps

    private func killZoomProcesses() async throws {
        try await shell.run("pkill -9 -f 'zoom.us' || true")
        try await shell.run("pkill -9 -x 'zoom.us' || true")
    }

    private func clearZoomCache() async throws {
        try await shell.run("rm -rf \"$HOME/Library/Application Support/zoom.us\"")
    }

    private func clearPreferences() async throws {
        try await shell.run("rm -f \"$HOME/Library/Preferences/us.zoom.*\"")
    }

    private func removeLogs() async throws {
        try await shell.run("rm -rf \"$HOME/Library/Logs/zoom.us\"")
    }

    private func findDuplicates() async throws {
        let command = """
        find /Applications "$HOME/Applications" "$HOME/Library/Application Support" -maxdepth 4 -iname "zoom*.app" 2>/dev/null
        """
        let result = try await shell.run(command, allowFailure: true)
        let paths = result.output
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }

        discoveredInstallations = Array(Set(paths))

        if discoveredInstallations.isEmpty {
            await log("No existing installations detected.")
        } else {
            await log("Found installations:")
            for url in discoveredInstallations {
                await log(" - \(url.path)")
            }
        }
    }

    private func removeInstallations() async throws {
        if discoveredInstallations.isEmpty {
            let defaults = [
                "/Applications/zoom.us.app",
                "/Applications/Zoom.app",
                "\(NSHomeDirectory())/Applications/zoom.us.app",
                "\(NSHomeDirectory())/Applications/Zoom.app"
            ].map { URL(fileURLWithPath: $0) }
            discoveredInstallations = defaults.filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        adminInstallationPaths = discoveredInstallations.filter { $0.path.hasPrefix("/Applications") }
        let userInstallations = discoveredInstallations.filter { !$0.path.hasPrefix("/Applications") }

        if !userInstallations.isEmpty {
            let joined = userInstallations.map { "\"\($0.path)\"" }.joined(separator: " ")
            try await shell.run("rm -rf \(joined)", allowFailure: true)
            for url in userInstallations {
                await log("Removed \(url.lastPathComponent)")
            }
        }

        if adminInstallationPaths.isEmpty {
            await log("No admin-level installations to remove.")
        } else {
            await log("Admin-level installations will be removed during privileged step:")
            for url in adminInstallationPaths {
                await log(" - \(url.path)")
            }
        }
    }

    private func downloadLatest() async throws {
        await updateProgress(nil, label: "Downloading Zoom")

        installerURL = try await downloader.downloadZoomInstaller(
            progressHandler: { [weak self] progress in
                Task { [weak self] in
                    await self?.updateProgress(progress, label: "Downloading Zoom")
                }
            },
            logHandler: { [weak self] message in
                Task { [weak self] in
                    await self?.log(message)
                }
            }
        )
    }

    private func performPrivilegedInstall() async throws {
        guard let installerURL else {
            throw ZoomFixError.missingInstaller
        }

        await updateProgress(nil, label: "Applying admin tasks")

        var commands: [String] = []

        if !adminInstallationPaths.isEmpty {
            let joined = adminInstallationPaths.map { "\"\($0.path)\"" }.joined(separator: " ")
            commands.append("rm -rf \(joined)")
        }

        commands.append("dscacheutil -flushcache || true")
        commands.append("killall -HUP mDNSResponder || true")
        commands.append("installer -pkg \"\(installerURL.path)\" -target /")

        let perms = """
        for app in "/Applications/zoom.us.app" "/Applications/Zoom.app" "/Applications/Zoom Workplace.app"; do
          if [ -d "$app" ]; then
            chown -R root:wheel "$app" && chmod -R 755 "$app";
          fi;
        done
        """
        commands.append(perms)

        let script = "bash -lc 'set -e; \(commands.joined(separator: " && "))'"
        try await shell.run(script, requireAdmin: true)
        await log("Admin tasks completed (remove/install/permissions/DNS flush)")
    }

    private func verifyInstallation() async throws {
        let candidates = [
            "/Applications/zoom.us.app",
            "/Applications/Zoom.app",
            "/Applications/Zoom Workplace.app"
        ]

        for app in candidates where FileManager.default.fileExists(atPath: app) {
            await log("Verified install at \(app)")
            await updateStatus(message: "Completed", kind: .success)
            return
        }

        throw ZoomFixError.installationMissing
    }

    // MARK: - UI Helpers

    @MainActor
    private func prepareForRun() {
        hadErrors = false
        installerURL = nil
        discoveredInstallations = []
        logs = []
        statusMessage = "Starting..."
        statusKind = .running
        progress = nil
        progressLabel = "Starting"
        isRunning = true
    }

    @MainActor
    private func updateStatus(message: String, kind: StatusKind) {
        statusMessage = message
        statusKind = kind
    }

    @MainActor
    private func updateProgress(_ value: Double?, label: String) {
        progress = value
        progressLabel = label
    }

    @MainActor
    private func log(_ message: String) {
        logs.append(message)
    }

    @MainActor
    private func finish() {
        statusKind = hadErrors ? .warning : .success
        statusMessage = hadErrors ? "Finished with warnings" : "Zoom repaired"
        progress = nil
        progressLabel = "Done"
        isRunning = false
    }

    @MainActor
    private func setDockerStatus(_ message: String, running: Bool, installing: Bool? = nil, auto: Bool? = nil) {
        dockerStatus = message
        isLaunchingDocker = running
        if let installing {
            isInstallingDocker = installing
        }
        if let auto {
            isAutoDockerFlow = auto
        }
    }
}

enum ZoomFixError: LocalizedError {
    case missingInstaller
    case installationMissing

    var errorDescription: String? {
        switch self {
        case .missingInstaller:
            return "Installer not available."
        case .installationMissing:
            return "Zoom not found after install."
        }
    }
}

struct DockerAvailabilityError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
