import Foundation
import Combine
import AppKit

/// One read-only, human-readable line in the preflight preview. Nothing in
/// this model is applied until the user explicitly confirms.
struct FixPreviewItem: Identifiable {
    enum Kind: String {
        case file = "File"
        case process = "Process"
        case setting = "Setting"
        case download = "Download"
    }

    let id = UUID()
    let kind: Kind
    let target: String
    let detail: String
}

enum StepResultState: String {
    case ok
    case failed
    case cancelled
    case skipped
}

/// What actually happened to one step of a confirmed run.
struct StepResult: Identifiable {
    let id = UUID()
    let title: String
    let state: StepResultState
    let detail: String
}

enum FixOutcomeState: String {
    case completed = "Completed"
    case completedWithWarnings = "Completed with warnings"
    case cancelled = "Cancelled"
    case failed = "Failed"
}

/// Post-action report built from recorded step results, not from intent.
struct FixOutcome {
    let state: FixOutcomeState
    let summary: String
    let results: [StepResult]
    let warnings: [String]

    var failures: [StepResult] { results.filter { $0.state == .failed } }
    var skipped: [StepResult] { results.filter { $0.state == .skipped || $0.state == .cancelled } }
}

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
    @Published private(set) var previewItems: [FixPreviewItem] = []
    @Published private(set) var isPreparingPreview = false
    @Published private(set) var isConfirmationPending = false
    @Published private(set) var cancellationRequested = false
    @Published private(set) var lastOutcome: FixOutcome? = nil

    private let processRegistry = ProcessRegistry()
    private let shell: ShellExecutor
    private let downloader = DownloadService()
    private var discoveredInstallations: [URL] = []
    private var adminInstallationPaths: [URL] = []
    private var installerURL: URL?
    private var hadErrors = false
    private var isCancellationRequested = false

    init() {
        shell = ShellExecutor(registry: processRegistry)
    }

    // MARK: - Preflight, confirmation and cancellation

    /// Read-only first step: inspect the machine and describe every change the
    /// repair would make. No shell command issued here mutates system state.
    @MainActor
    func prepareFixPreview() {
        guard !isRunning, !isPreparingPreview else { return }
        processRegistry.reset()
        isPreparingPreview = true
        isConfirmationPending = false
        previewItems = []
        lastOutcome = nil
        cancellationRequested = false

        Task { await buildPreview() }
    }

    @MainActor
    private func buildPreview() async {
        var items: [FixPreviewItem] = []

        // /etc/hosts — the same detector used by repairHostsFile().
        let hosts = await readOnlyOutput("cat /etc/hosts 2>/dev/null || true")
        let blockedLines = zoomBlockingHostLines(in: hosts)
        if !blockedLines.isEmpty {
            items.append(FixPreviewItem(
                kind: .file,
                target: "/etc/hosts",
                detail: "Remove \(blockedLines.count) Zoom-blocking line(s): \(blockedLines.joined(separator: " | ")) (admin)"
            ))
        }

        // Application Firewall entries for installed Zoom binaries.
        let zoomBinaries = zoomApplicationCandidates()
        let installedBinaries = zoomBinaries.filter { FileManager.default.fileExists(atPath: $0) }
        if !installedBinaries.isEmpty {
            items.append(FixPreviewItem(
                kind: .setting,
                target: "macOS Application Firewall",
                detail: "Remove/re-add and unblock: \(installedBinaries.joined(separator: ", ")) (admin)"
            ))
        }

        // DHCP renewal for degraded interfaces.
        let interfaces = apipaInterfaces(in: await readOnlyOutput("ifconfig -a 2>/dev/null || true"))
        for iface in interfaces {
            items.append(FixPreviewItem(
                kind: .setting,
                target: "Network interface \(iface)",
                detail: "Renew DHCP lease with `ipconfig set \(iface) DHCP` (admin)"
            ))
        }

        // Running Zoom processes.
        let processOutput = await readOnlyOutput("pgrep -fl 'zoom.us' 2>/dev/null || true")
        let zoomProcesses = processOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !zoomProcesses.isEmpty {
            items.append(FixPreviewItem(
                kind: .process,
                target: "Running Zoom processes",
                detail: "Force quit: \(zoomProcesses.joined(separator: " | "))"
            ))
        }

        // User-level files that will be deleted.
        let home = NSHomeDirectory()
        let cachePath = "\(home)/Library/Application Support/zoom.us"
        if FileManager.default.fileExists(atPath: cachePath) {
            items.append(FixPreviewItem(kind: .file, target: cachePath, detail: "Delete Zoom cache directory"))
        }
        let logPath = "\(home)/Library/Logs/zoom.us"
        if FileManager.default.fileExists(atPath: logPath) {
            items.append(FixPreviewItem(kind: .file, target: logPath, detail: "Delete Zoom logs directory"))
        }
        let preferenceOutput = await readOnlyOutput("printf '%s\\n' \"$HOME\"/Library/Preferences/us.zoom.* 2>/dev/null || true")
        let preferences = preferenceOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { FileManager.default.fileExists(atPath: $0) }
        for path in preferences {
            items.append(FixPreviewItem(kind: .file, target: path, detail: "Delete Zoom preference file"))
        }

        // Installed copies, using the same discovery command as findDuplicates().
        let foundPaths = await readOnlyOutput(zoomInstallationDiscoveryCommand())
        let installations = Array(Set(foundPaths.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }))
        for url in installations {
            let privileged = url.path.hasPrefix("/Applications")
            items.append(FixPreviewItem(
                kind: .file,
                target: url.path,
                detail: privileged ? "Remove existing admin-level copy (admin)" : "Remove existing user-level copy"
            ))
        }

        items.append(FixPreviewItem(
            kind: .download,
            target: "https://zoom.us/client/latest/Zoom.pkg",
            detail: "Download the latest Zoom installer to a temporary .pkg file"
        ))
        items.append(FixPreviewItem(
            kind: .file,
            target: "/Applications (Zoom application bundle)",
            detail: "Install the downloaded package; replace Zoom.app bundles found above"
        ))
        items.append(FixPreviewItem(
            kind: .setting,
            target: "System settings touched by the privileged step",
            detail: "Set root:wheel / 755 on Zoom bundles, flush DNS cache, restart mDNSResponder, re-add/unblock firewall entries (admin)"
        ))

        previewItems = items
        isPreparingPreview = false
        isConfirmationPending = true
        log("[preview] \(items.count) planned change(s) listed; nothing has been changed yet")
        updateStatus(message: "Review the preview before continuing", kind: .idle)
    }

    /// Executes only after the user has seen the preview and pressed Confirm.
    @MainActor
    func confirmFix() {
        guard isConfirmationPending, !isRunning else { return }
        isConfirmationPending = false
        previewItems = []

        Task {
            prepareForRun()
            await runSequence()
        }
    }

    @MainActor
    func cancelPreview() {
        guard isConfirmationPending else { return }
        isConfirmationPending = false
        previewItems = []
        statusMessage = "Preview cancelled; no changes made"
        statusKind = .idle
    }

    /// Requests cancellation of an in-flight run and terminates any child
    /// process tracked by the shared shell registry.
    @MainActor
    func cancelFix() {
        guard isRunning else { return }
        isCancellationRequested = true
        cancellationRequested = true
        processRegistry.cancelAll()
        logs.append("[cancel] Cancellation requested; stopping active command")
        statusMessage = "Cancelling repair..."
        statusKind = .warning
        progressLabel = "Cancelling"
    }

    @MainActor
    func clearOutcome() {
        lastOutcome = nil
    }

    @MainActor
    private func readOnlyOutput(_ command: String) async -> String {
        do {
            return (try await shell.run(command, allowFailure: true)).output
        } catch {
            return ""
        }
    }

    // MARK: - Sequence

    @MainActor
    private func runSequence() async {
        let steps: [(String, () async throws -> Void)] = [
            // ── NEW: system-level change detection & repair ──────────────────
            ("Check hosts file for Zoom blocks",       repairHostsFile),
            ("Check macOS firewall for Zoom blocks",   repairFirewallRules),
            ("Check network interfaces (APIPA/link-local)", repairNetworkInterfaces),
            ("Check TLS / Keychain trust for Zoom",    checkTLSTrust),
            ("Check VPN / network extensions",         auditNetworkExtensions),
            ("Check SIP status",                       checkSIPStatus),
            // ── existing steps ───────────────────────────────────────────────
            ("Kill Zoom processes",                    killZoomProcesses),
            ("Clear Zoom cache",                       clearZoomCache),
            ("Clear Zoom preferences",                 clearPreferences),
            ("Remove Zoom logs",                       removeLogs),
            ("Find duplicate installations",           findDuplicates),
            ("Remove all Zoom installations",          removeInstallations),
            ("Download latest Zoom",                   downloadLatest),
            ("Install & repair with admin tasks",      performPrivilegedInstall),
            ("Verify installation",                    verifyInstallation)
        ]

        var results: [StepResult] = []

        for (title, action) in steps {
            if isCancellationRequested {
                results.append(StepResult(title: title, state: .skipped, detail: "Not started; cancelled"))
                log("[cancel] Skipped \(title)")
                continue
            }

            updateStatus(message: title, kind: .running)
            log("== \(title) ==")

            do {
                try await action()

                if isCancellationRequested {
                    results.append(StepResult(title: title, state: .cancelled, detail: "Interrupted by cancellation; partial effects may remain"))
                    log("[cancel] \(title): interrupted by cancellation")
                } else {
                    results.append(StepResult(title: title, state: .ok, detail: "Completed"))
                    log("[ok] \(title)")
                }
            } catch {
                if isCancellationRequested {
                    results.append(StepResult(title: title, state: .cancelled, detail: "Interrupted: \(error.localizedDescription); partial effects may remain"))
                    log("[cancel] \(title): interrupted: \(error.localizedDescription)")
                } else {
                    hadErrors = true
                    results.append(StepResult(title: title, state: .failed, detail: error.localizedDescription))
                    log("[error] \(title): \(error.localizedDescription)")
                }
            }
        }

        finish(results: results)
    }

    // MARK: - Shared read-only detectors (preview and repair use the same rules)

    private var zoomHostDomains: [String] {
        [
            "zoom.us", "us04web.zoom.us", "us02web.zoom.us",
            "us06web.zoom.us", "us02ws.zoom.us", "us04ws.zoom.us",
            "controlplane.zoom.us", "us04mon.zoom.us",
            "us04stun1.zoom.us", "logcs.zoom.us"
        ]
    }

    private func zoomBlockingHostLines(in contents: String) -> [String] {
        contents.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.isEmpty else { return false }
            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return false }
            let ip = parts[0]
            let isBlockEntry = ip == "0.0.0.0" || ip.hasPrefix("127.")
            let hostsZoom = parts.dropFirst().contains { domain in
                zoomHostDomains.contains(where: { domain.hasSuffix($0) })
            }
            return isBlockEntry && hostsZoom
        }
    }

    private func zoomApplicationCandidates() -> [String] {
        ["/Applications/zoom.us.app", "/Applications/Zoom.app", "/Applications/Zoom Workplace.app"]
    }

    private func apipaInterfaces(in output: String) -> [String] {
        var found: [String] = []
        var current = ""
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") {
                current = String(line.prefix(while: { $0 != ":" }))
            }
            if trimmed.hasPrefix("inet 169.254."), !current.isEmpty {
                found.append(current)
            }
        }
        return found
    }

    private func zoomInstallationDiscoveryCommand() -> String {
        """
        find /Applications "$HOME/Applications" "$HOME/Library/Application Support" -maxdepth 4 -iname "zoom*.app" 2>/dev/null
        """
    }

    // MARK: - System-change detection & repair (Error 1132)

    /// Zoom error 1132 is often caused by /etc/hosts entries that redirect or
    /// block Zoom's signalling and relay servers. We scan for known Zoom domains
    /// and remove any lines that point them at 0.0.0.0 / 127.x / a non-Zoom IP.
    private func repairHostsFile() async throws {
        let hostsPath = "/etc/hosts"
        let contents = try String(contentsOfFile: hostsPath, encoding: .utf8)
        let removed = zoomBlockingHostLines(in: contents)
        var lines = contents.components(separatedBy: .newlines)
        lines.removeAll { removed.contains($0) }

        if removed.isEmpty {
            await log("[hosts] No Zoom-blocking entries found in /etc/hosts")
            return
        }

        await log("[hosts] Found \(removed.count) blocking entry(s) — removing via admin:")
        for r in removed { await log("  - \(r)") }

        let newContents = lines.joined(separator: "\n")
        let escaped = newContents
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
        let script = "bash -lc \"printf '%s' '\(escaped)' > /etc/hosts\""
        try await shell.run(script, requireAdmin: true)
        await log("[hosts] Blocking entries removed successfully")
    }

    /// The macOS Application Firewall can be configured (e.g. by parental
    /// controls, MDM, or third-party apps) to block ZoomOpener / CptHost.
    /// We check for blocked entries and remove them, then ensure the
    /// firewall allows Zoom's binaries.
    private func repairFirewallRules() async throws {
        // socketfilterfw manages the built-in Application Firewall
        let fwPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard FileManager.default.fileExists(atPath: fwPath) else {
            await log("[firewall] socketfilterfw not found — skipping")
            return
        }

        let listResult = try await shell.run("\(fwPath) --listapps", allowFailure: true)
        let output = listResult.output

        let zoomBinaries = zoomApplicationCandidates()

        // Look for BLOCK state on any Zoom binary
        let blockedPattern = #"BLOCK"#
        let zoomBlocked = zoomBinaries.contains { appPath in
            output.contains(appPath) && output.range(of: blockedPattern) != nil
        }

        if !zoomBlocked {
            await log("[firewall] No Zoom entries blocked in Application Firewall")
        } else {
            await log("[firewall] Zoom appears blocked — resetting firewall entries")
        }

        // Whether blocked or not, ensure Zoom is explicitly unblocked/allowed
        var cmds: [String] = []
        for appPath in zoomBinaries {
            if FileManager.default.fileExists(atPath: appPath) {
                // Remove old entry then re-add as allowed
                cmds.append("\(fwPath) --remove \"\(appPath)\" || true")
                cmds.append("\(fwPath) --add \"\(appPath)\"")
                cmds.append("\(fwPath) --unblockapp \"\(appPath)\" || true")
            }
        }

        if cmds.isEmpty {
            await log("[firewall] Zoom not yet installed; will re-run after install")
            return
        }

        let script = "bash -lc '" + cmds.joined(separator: " && ") + "'"
        try await shell.run(script, requireAdmin: true)
        await log("[firewall] Zoom firewall entries updated")
    }

    /// APIPA / link-local addresses (169.254.x.x) on the primary interface
    /// indicate DHCP failure and will break Zoom's connectivity (error 1132).
    /// We detect degraded interfaces and attempt a DHCP renewal.
    private func repairNetworkInterfaces() async throws {
        let result = try await shell.run("ifconfig -a", allowFailure: true)
        let output = result.output

        // Find interfaces with 169.254.x.x using the preview's detector.
        let degradedInterfaces = apipaInterfaces(in: output)

        if degradedInterfaces.isEmpty {
            await log("[network] No APIPA/link-local addresses detected — interfaces look healthy")
            return
        }

        await log("[network] APIPA addresses detected on: \(degradedInterfaces.joined(separator: ", "))")
        await log("[network] Attempting DHCP renewal...")

        for iface in degradedInterfaces {
            let renewCmd = "ipconfig set \(iface) DHCP"
            let renewResult = try await shell.run(renewCmd, requireAdmin: true, allowFailure: true)
            if renewResult.exitCode == 0 {
                await log("[network] DHCP renewal issued for \(iface)")
            } else {
                await log("[network][warn] DHCP renewal failed for \(iface): \(renewResult.output)")
                hadErrors = true
            }
        }
    }

    /// Validates that zoom.us TLS certificates are trusted by the system
    /// keychain. A corrupted or enterprise-replaced root CA can break
    /// Zoom's HTTPS connections and produce error 1132.
    private func checkTLSTrust() async throws {
        let checkCmd = """
        bash -lc 'openssl s_client -connect zoom.us:443 -brief </dev/null 2>&1 | head -5'
        """
        let result = try await shell.run(checkCmd, allowFailure: true)
        let output = result.output

        if output.contains("Verification: OK") || output.contains("verify return:1") {
            await log("[tls] zoom.us TLS certificate verifies OK")
            return
        }

        if output.contains("verification error") || output.contains("unable to verify") {
            await log("[tls][warn] TLS verification failed for zoom.us: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            await log("[tls][warn] This may indicate a tampered root CA or enterprise MITM proxy.")
            await log("[tls][warn] Recommended action: open Keychain Access → System Roots and check for untrusted / modified certs.")
            hadErrors = true
        } else {
            await log("[tls] zoom.us TLS check result: \(output.prefix(120))")
        }
    }

    /// VPN clients and network extensions can intercept Zoom's UDP relay
    /// traffic (ports 8801–8802, 3478, 3479) causing error 1132.
    /// We list loaded network kernel extensions as an advisory.
    private func auditNetworkExtensions() async throws {
        // Check for loaded network extensions via systemextensionsctl
        let sysextResult = try await shell.run(
            "systemextensionsctl list 2>/dev/null || echo 'unavailable'",
            allowFailure: true
        )

        let kextResult = try await shell.run(
            "kextstat 2>/dev/null | grep -i -E 'vpn|tunnel|filter|proxy|checkpoint|sophos|symantec|mcafee|crowdstrike|carbon' || echo 'none'",
            allowFailure: true
        )

        let kextOutput = kextResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if kextOutput == "none" || kextOutput.isEmpty {
            await log("[netext] No known VPN/security kernel extensions detected")
        } else {
            await log("[netext][warn] Potentially interfering network extensions found:")
            for line in kextOutput.components(separatedBy: .newlines) where !line.isEmpty {
                await log("  \(line)")
            }
            await log("[netext][warn] If Zoom error 1132 persists, try disabling VPN/security software and retesting.")
        }

        let sysextOutput = sysextResult.output
        if sysextOutput.contains("com.apple") || sysextOutput == "unavailable" {
            // Only Apple extensions — fine
        } else {
            let thirdParty = sysextOutput.components(separatedBy: .newlines)
                .filter { !$0.contains("com.apple") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !thirdParty.isEmpty {
                await log("[netext][info] Third-party system extensions active:")
                for line in thirdParty { await log("  \(line)") }
            }
        }
    }

    /// SIP (System Integrity Protection) being disabled can allow
    /// malicious software to tamper with Zoom's install, causing 1132.
    /// We report the SIP state and advise re-enabling if off.
    private func checkSIPStatus() async throws {
        let result = try await shell.run("csrutil status", allowFailure: true)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if output.contains("enabled") {
            await log("[sip] System Integrity Protection is ENABLED ✓")
        } else if output.contains("disabled") {
            await log("[sip][warn] System Integrity Protection is DISABLED.")
            await log("[sip][warn] SIP being off allows deep system modifications that can break Zoom.")
            await log("[sip][warn] To re-enable: boot into Recovery Mode → Utilities → Terminal → `csrutil enable`")
            hadErrors = true
        } else {
            await log("[sip] SIP status: \(output)")
        }
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

    // MARK: - Existing Steps

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
        let result = try await shell.run(zoomInstallationDiscoveryCommand(), allowFailure: true)
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

        // Re-unblock in firewall after fresh install
        let fwPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        let fwUnblock = """
        for app in "/Applications/zoom.us.app" "/Applications/Zoom.app" "/Applications/Zoom Workplace.app"; do
          if [ -d "$app" ]; then
            \(fwPath) --add "$app" 2>/dev/null || true
            \(fwPath) --unblockapp "$app" 2>/dev/null || true
          fi
        done
        """
        commands.append(fwUnblock)

        let script = "bash -lc 'set -e; \(commands.joined(separator: " && "))'"
        try await shell.run(script, requireAdmin: true)
        await log("Admin tasks completed (remove/install/permissions/DNS flush/firewall)")
    }

    private func verifyInstallation() async throws {
        for app in zoomApplicationCandidates() where FileManager.default.fileExists(atPath: app) {
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
        adminInstallationPaths = []
        logs = []
        processRegistry.reset()
        isCancellationRequested = false
        cancellationRequested = false
        lastOutcome = nil
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
    private func finish(results: [StepResult]) {
        let failures = results.filter { $0.state == .failed }
        let warnings = logs.filter { $0.contains("[warn]") }
        let completedCount = results.filter { $0.state == .ok || $0.state == .cancelled }.count

        let outcomeState: FixOutcomeState
        let message: String
        if isCancellationRequested {
            outcomeState = .cancelled
            message = "Cancelled after \(completedCount) of \(results.count) step(s); \(failures.count) failed before cancellation. Partial changes may remain."
        } else if !failures.isEmpty {
            outcomeState = .failed
            message = "Completed with \(failures.count) failed step(s) out of \(results.count). See failures below."
        } else if hadErrors || !warnings.isEmpty {
            outcomeState = .completedWithWarnings
            message = "Completed all \(results.count) step(s) with \(warnings.count) advisory warning(s)."
        } else {
            outcomeState = .completed
            message = "Zoom repaired; all \(results.count) step(s) completed."
        }

        switch outcomeState {
        case .completed: statusKind = .success
        case .cancelled, .completedWithWarnings: statusKind = .warning
        case .failed: statusKind = .failed
        }
        statusMessage = message
        progress = nil
        progressLabel = "Done"
        isRunning = false
        cancellationRequested = isCancellationRequested
        lastOutcome = FixOutcome(state: outcomeState, summary: message, results: results, warnings: warnings)
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
