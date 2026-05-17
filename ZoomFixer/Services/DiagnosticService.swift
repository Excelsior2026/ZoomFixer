import Foundation

/// Standalone diagnostic-only scans that do not modify the system.
/// Used by the "Scan Only" path in the UI.
final class DiagnosticService: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var results: [DiagnosticResult] = []

    private let shell = ShellExecutor()

    struct DiagnosticResult: Identifiable {
        let id = UUID()
        let title: String
        let status: Status
        let detail: String

        enum Status { case ok, warn, fail }
    }

    func runScan() {
        guard !isScanning else { return }
        Task {
            await MainActor.run { self.isScanning = true; self.results = [] }
            var r: [DiagnosticResult] = []

            r.append(await checkHostsFile())
            r.append(await checkFirewall())
            r.append(await checkNetworkInterfaces())
            r.append(await checkPortReachability())
            r.append(await checkProxy())
            r.append(await checkMTU())
            r.append(await checkTLS())
            r.append(await checkSIP())
            r.append(await checkNetworkExtensions())
            r.append(await checkLaunchAgents())
            r.append(await checkCrashLogs())
            r.append(await checkMACAddress())

            await MainActor.run { self.results = r; self.isScanning = false }
        }
    }

    // MARK: - Individual checks

    private func checkHostsFile() async -> DiagnosticResult {
        let zoomDomains = ["zoom.us", "us04web.zoom.us", "us02web.zoom.us",
                           "controlplane.zoom.us", "logcs.zoom.us"]
        let contents = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        let blocked = zoomDomains.filter { domain in
            contents.components(separatedBy: .newlines).contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#") else { return false }
                return (t.hasPrefix("0.0.0.0") || t.contains("127.")) && t.contains(domain)
            }
        }
        if blocked.isEmpty {
            return .init(title: "Hosts file", status: .ok, detail: "No Zoom domains blocked")
        }
        return .init(title: "Hosts file", status: .fail,
                     detail: "Blocking entries found: \(blocked.joined(separator: ", "))")
    }

    private func checkFirewall() async -> DiagnosticResult {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard FileManager.default.fileExists(atPath: fw) else {
            return .init(title: "Firewall", status: .ok, detail: "socketfilterfw not present")
        }
        let res = (try? await shell.run("\(fw) --listapps", allowFailure: true))?.output ?? ""
        let zoomApps = ["/Applications/zoom.us.app", "/Applications/Zoom.app"]
        let blocked = zoomApps.filter { app in res.contains(app) && res.contains("BLOCK") }
        if blocked.isEmpty {
            return .init(title: "Firewall", status: .ok, detail: "No Zoom binaries blocked")
        }
        return .init(title: "Firewall", status: .fail,
                     detail: "Blocked: \(blocked.joined(separator: ", "))")
    }

    private func checkNetworkInterfaces() async -> DiagnosticResult {
        let res = (try? await shell.run("ifconfig -a", allowFailure: true))?.output ?? ""
        let apipa = res.components(separatedBy: .newlines).filter { $0.contains("inet 169.254.") }
        if apipa.isEmpty {
            return .init(title: "Network interfaces", status: .ok, detail: "No APIPA addresses detected")
        }
        return .init(title: "Network interfaces", status: .fail,
                     detail: "APIPA (DHCP failure) detected on \(apipa.count) interface(s)")
    }

    private func checkPortReachability() async -> DiagnosticResult {
        // TCP reachability to Zoom signalling servers
        let targets = [("us04web.zoom.us", 443), ("controlplane.zoom.us", 443)]
        var failed: [String] = []
        for (host, port) in targets {
            let cmd = "nc -z -w 5 \(host) \(port) 2>&1"
            let res = (try? await shell.run(cmd, allowFailure: true))
            if (res?.exitCode ?? 1) != 0 {
                failed.append("\(host):\(port)")
            }
        }
        if failed.isEmpty {
            return .init(title: "Port reachability", status: .ok,
                         detail: "Zoom signalling ports reachable")
        }
        return .init(title: "Port reachability", status: .fail,
                     detail: "Unreachable: \(failed.joined(separator: ", "))")
    }

    private func checkProxy() async -> DiagnosticResult {
        let res = (try? await shell.run("scutil --proxy", allowFailure: true))?.output ?? ""
        let hasProxy = res.contains("HTTPEnable = 1") || res.contains("HTTPSEnable = 1")
            || res.contains("ProxyAutoConfigEnable = 1")
        if !hasProxy {
            return .init(title: "Proxy settings", status: .ok, detail: "No system proxy configured")
        }
        let summary = res.components(separatedBy: .newlines)
            .filter { $0.contains("Enable") || $0.contains("Proxy") || $0.contains("PAC") }
            .joined(separator: "; ")
        return .init(title: "Proxy settings", status: .warn,
                     detail: "Active proxy detected: \(summary)")
    }

    private func checkMTU() async -> DiagnosticResult {
        // Get primary interface
        let routeRes = (try? await shell.run("route get default 2>/dev/null | awk '/interface/{print $2}'", allowFailure: true))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !routeRes.isEmpty else {
            return .init(title: "MTU", status: .warn, detail: "Could not determine primary interface")
        }
        let mtuRes = (try? await shell.run("networksetup -getMTU \"\(routeRes)\" 2>/dev/null || ifconfig \(routeRes) | awk '/mtu/{print $NF}'", allowFailure: true))?.output ?? ""
        let digits = mtuRes.components(separatedBy: .whitespaces).compactMap { Int($0) }.first ?? 0
        if digits == 0 {
            return .init(title: "MTU", status: .warn, detail: "Could not read MTU for \(routeRes)")
        }
        if digits < 1400 {
            return .init(title: "MTU", status: .fail,
                         detail: "MTU is \(digits) on \(routeRes) — below 1400, may cause Zoom packet loss")
        }
        return .init(title: "MTU", status: .ok, detail: "MTU = \(digits) on \(routeRes)")
    }

    private func checkTLS() async -> DiagnosticResult {
        let res = (try? await shell.run(
            "openssl s_client -connect zoom.us:443 -brief </dev/null 2>&1 | head -5",
            allowFailure: true))?.output ?? ""
        if res.contains("Verification: OK") || res.contains("verify return:1") {
            return .init(title: "TLS / Keychain trust", status: .ok, detail: "zoom.us TLS cert OK")
        }
        return .init(title: "TLS / Keychain trust", status: .warn,
                     detail: "TLS issue: \(res.prefix(120))")
    }

    private func checkSIP() async -> DiagnosticResult {
        let res = (try? await shell.run("csrutil status", allowFailure: true))?.output ?? ""
        if res.contains("enabled") {
            return .init(title: "SIP", status: .ok, detail: "System Integrity Protection enabled")
        }
        return .init(title: "SIP", status: .warn, detail: "SIP disabled — system may be tampered")
    }

    private func checkNetworkExtensions() async -> DiagnosticResult {
        let res = (try? await shell.run(
            "kextstat 2>/dev/null | grep -iE 'vpn|tunnel|filter|proxy|checkpoint|sophos|symantec|mcafee|crowdstrike|carbon' || echo ''",
            allowFailure: true))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if res.isEmpty {
            return .init(title: "Network extensions", status: .ok,
                         detail: "No known interfering VPN/security kexts")
        }
        let count = res.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
        return .init(title: "Network extensions", status: .warn,
                     detail: "\(count) potentially interfering extension(s) loaded")
    }

    private func checkLaunchAgents() async -> DiagnosticResult {
        let paths = [
            "\(NSHomeDirectory())/Library/LaunchAgents",
            "/Library/LaunchDaemons"
        ]
        var found: [String] = []
        for path in paths {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            found += items.filter { $0.lowercased().contains("zoom") }
        }
        if found.isEmpty {
            return .init(title: "LaunchAgents/Daemons", status: .ok,
                         detail: "No Zoom-related launch agents found")
        }
        return .init(title: "LaunchAgents/Daemons", status: .warn,
                     detail: "Found: \(found.joined(separator: ", "))")
    }

    private func checkCrashLogs() async -> DiagnosticResult {
        let dir = "\(NSHomeDirectory())/Library/Logs/DiagnosticReports"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let crashes = items.filter { $0.lowercased().contains("zoom") && $0.hasSuffix(".crash") }
        if crashes.isEmpty {
            return .init(title: "Crash logs", status: .ok, detail: "No recent Zoom crash reports")
        }
        return .init(title: "Crash logs", status: .warn,
                     detail: "\(crashes.count) crash report(s) found — may indicate install corruption")
    }

    private func checkMACAddress() async -> DiagnosticResult {
        let res = (try? await shell.run(
            "ifconfig en0 2>/dev/null | awk '/ether/{print $2}'",
            allowFailure: true))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if res.isEmpty {
            return .init(title: "MAC address (en0)", status: .warn, detail: "Could not read en0 MAC")
        }
        return .init(title: "MAC address (en0)", status: .ok,
                     detail: "Current MAC: \(res)")
    }
}
