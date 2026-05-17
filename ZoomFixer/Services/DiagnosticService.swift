import Foundation

/// Runs a scan-only diagnostic pass and returns a report without
/// modifying any system state.
final class DiagnosticService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var probeResults: [NetworkProbeService.ProbeResult] = []

    private let shell = ShellExecutor()
    private let probe = NetworkProbeService()

    // MARK: - Public

    func runDiagnostic() {
        guard !isRunning else { return }
        Task {
            await MainActor.run { self.isRunning = true; self.entries = [] }

            let logger: (LogEntry) -> Void = { entry in
                Task { @MainActor in self.entries.append(entry) }
            }

            logger(LogEntry(level: .info, category: "scan", message: "=== ZoomFixer Diagnostic Scan ==="))

            await checkHostsReadOnly(logger: logger)
            await checkFirewallReadOnly(logger: logger)
            await checkNetworkInterfacesReadOnly(logger: logger)
            await checkTLSReadOnly(logger: logger)
            await checkProxySettings(logger: logger)
            await checkMDNS(logger: logger)
            await checkMTU(logger: logger)
            await checkLaunchAgents(logger: logger)
            await checkCrashLogs(logger: logger)
            await checkSIPReadOnly(logger: logger)
            await checkVPNExtensions(logger: logger)

            let results = await probe.probeAll(logger: logger)
            await MainActor.run { self.probeResults = results }

            logger(LogEntry(level: .info, category: "scan", message: "=== Scan complete ==="))
            await MainActor.run { self.isRunning = false }
        }
    }

    // MARK: - Read-only checks

    private func checkHostsReadOnly(logger: (LogEntry) -> Void) async {
        let zoomDomains = ["zoom.us","us04web.zoom.us","us02web.zoom.us","controlplane.zoom.us"]
        guard let contents = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            logger(LogEntry(level: .warn, category: "hosts", message: "Cannot read /etc/hosts")); return
        }
        var found = false
        for line in contents.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.isEmpty else { continue }
            let parts = t.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            let ip = parts[0]
            if (ip == "0.0.0.0" || ip.hasPrefix("127.")) &&
               parts.dropFirst().contains(where: { d in zoomDomains.contains(where: { d.hasSuffix($0) }) }) {
                logger(LogEntry(level: .warn, category: "hosts", message: "BLOCKING entry: \(line)"))
                found = true
            }
        }
        if !found { logger(LogEntry(level: .info, category: "hosts", message: "No Zoom-blocking entries in /etc/hosts ✓")) }
    }

    private func checkFirewallReadOnly(logger: (LogEntry) -> Void) async {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard FileManager.default.fileExists(atPath: fw) else {
            logger(LogEntry(level: .info, category: "firewall", message: "socketfilterfw not present — skipping")); return
        }
        let r = try? await shell.run("\(fw) --listapps", allowFailure: true)
        let out = r?.output ?? ""
        let hasZoom = out.contains("zoom") || out.contains("Zoom")
        logger(LogEntry(
            level: hasZoom ? .info : .warn,
            category: "firewall",
            message: hasZoom ? "Zoom found in firewall list" : "Zoom not found in firewall application list"
        ))
    }

    private func checkNetworkInterfacesReadOnly(logger: (LogEntry) -> Void) async {
        let r = try? await shell.run("ifconfig -a", allowFailure: true)
        let out = r?.output ?? ""
        let hasAPIPA = out.contains("inet 169.254.")
        logger(LogEntry(
            level: hasAPIPA ? .warn : .info,
            category: "network",
            message: hasAPIPA ? "APIPA address detected — DHCP may have failed" : "Network interfaces look healthy ✓"
        ))
    }

    private func checkTLSReadOnly(logger: (LogEntry) -> Void) async {
        let r = try? await shell.run(
            "openssl s_client -connect zoom.us:443 -brief </dev/null 2>&1 | head -5",
            allowFailure: true
        )
        let out = r?.output ?? ""
        if out.contains("Verification: OK") || out.contains("verify return:1") {
            logger(LogEntry(level: .info, category: "tls", message: "zoom.us TLS certificate verifies OK ✓"))
        } else {
            logger(LogEntry(level: .warn, category: "tls", message: "TLS verification issue: \(out.prefix(120))"))
        }
    }

    private func checkProxySettings(logger: (LogEntry) -> Void) async {
        let r = try? await shell.run("scutil --proxy", allowFailure: true)
        let out = r?.output ?? ""
        if out.contains("HTTPEnable : 1") || out.contains("HTTPSEnable : 1") || out.contains("ProxyAutoConfigEnable : 1") {
            logger(LogEntry(level: .warn, category: "proxy",
                message: "System proxy is ENABLED. This may intercept Zoom traffic.\n\(out.prefix(300))"))
        } else {
            logger(LogEntry(level: .info, category: "proxy", message: "No system proxy detected ✓"))
        }
        // Also check environment variables
        for key in ["HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy"] {
            if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty {
                logger(LogEntry(level: .warn, category: "proxy", message: "Env var \(key)=\(val)"))
            }
        }
    }

    private func checkMDNS(logger: (LogEntry) -> Void) async {
        let r = try? await shell.run("pgrep -x mDNSResponder", allowFailure: true)
        if r?.exitCode == 0 {
            logger(LogEntry(level: .info, category: "mdns", message: "mDNSResponder is running ✓"))
        } else {
            logger(LogEntry(level: .warn, category: "mdns", message: "mDNSResponder is NOT running — Zoom peer discovery may fail"))
        }
    }

    private func checkMTU(logger: (LogEntry) -> Void) async {
        let ifaces = ["en0","en1","utun0"]
        for iface in ifaces {
            let r = try? await shell.run("networksetup -getMTU \(iface) 2>/dev/null", allowFailure: true)
            let out = (r?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty, r?.exitCode == 0 else { continue }
            if let mtuStr = out.components(separatedBy: " ").last, let mtu = Int(mtuStr) {
                if mtu < 1400 {
                    logger(LogEntry(level: .warn, category: "mtu",
                        message: "\(iface) MTU=\(mtu) is low (<1400) — may cause Zoom packet fragmentation"))
                } else {
                    logger(LogEntry(level: .info, category: "mtu", message: "\(iface) MTU=\(mtu) ✓"))
                }
            }
        }
    }

    private func checkLaunchAgents(logger: (LogEntry) -> Void) async {
        let dirs = [
            "\(NSHomeDirectory())/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons"
        ]
        var found = false
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.lowercased().contains("zoom") {
                logger(LogEntry(level: .warn, category: "launchd",
                    message: "Zoom LaunchAgent/Daemon found: \(dir)/\(file)"))
                found = true
            }
        }
        if !found { logger(LogEntry(level: .info, category: "launchd", message: "No Zoom LaunchAgents/Daemons found ✓")) }
    }

    private func checkCrashLogs(logger: (LogEntry) -> Void) async {
        let crashDir = "\(NSHomeDirectory())/Library/Logs/DiagnosticReports"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) else {
            logger(LogEntry(level: .info, category: "crash", message: "No diagnostic reports directory found")); return
        }
        let zoomCrashes = files.filter { $0.lowercased().contains("zoom") }.sorted().suffix(5)
        if zoomCrashes.isEmpty {
            logger(LogEntry(level: .info, category: "crash", message: "No recent Zoom crash reports ✓"))
        } else {
            logger(LogEntry(level: .warn, category: "crash", message: "Recent Zoom crash reports:"))
            for f in zoomCrashes {
                let path = "\(crashDir)/\(f)"
                // Extract just the exception line
                if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    let exception = content.components(separatedBy: .newlines)
                        .first(where: { $0.contains("Exception") || $0.contains("Signal") })
                        ?? "(no exception line found)"
                    logger(LogEntry(level: .warn, category: "crash", message: "  \(f): \(exception)"))
                }
            }
        }
    }

    private func checkSIPReadOnly(logger: (LogEntry) -> Void) async {
        let r = try? await shell.run("csrutil status", allowFailure: true)
        let out = (r?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if out.contains("enabled") {
            logger(LogEntry(level: .info, category: "sip", message: "SIP is ENABLED ✓"))
        } else if out.contains("disabled") {
            logger(LogEntry(level: .warn, category: "sip",
                message: "SIP is DISABLED — system files can be tampered with"))
        } else {
            logger(LogEntry(level: .info, category: "sip", message: "SIP: \(out)"))
        }
    }

    private func checkVPNExtensions(logger: (LogEntry) -> Void) async {
        let r = try? await shell.run(
            "kextstat 2>/dev/null | grep -iE 'vpn|tunnel|filter|proxy|checkpoint|sophos|symantec|mcafee|crowdstrike|carbon' || echo ''",
            allowFailure: true
        )
        let out = (r?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty {
            logger(LogEntry(level: .info, category: "netext", message: "No interfering VPN/security kexts detected ✓"))
        } else {
            logger(LogEntry(level: .warn, category: "netext", message: "Potentially interfering kexts: \(out.prefix(200))"))
        }
    }

    // MARK: - Report export

    func exportReport() -> String {
        let header = "ZoomFixer Diagnostic Report — \(Date())\n" + String(repeating: "=", count: 60) + "\n"
        let body = entries.map { $0.formatted }.joined(separator: "\n")
        return header + body
    }

    func saveReportToDesktop() -> URL? {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "ZoomFixer_Report_\(formatter.string(from: Date())).txt"
        let url = desktop.appendingPathComponent(name)
        try? exportReport().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
