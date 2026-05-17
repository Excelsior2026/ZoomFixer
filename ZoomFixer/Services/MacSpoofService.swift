import Foundation

/// Temporarily spoofs the MAC address of a network interface.
///
/// On macOS the `ifconfig` command accepts:
///   sudo ifconfig <iface> ether <new-mac>
/// The original MAC is restored by bringing the interface down/up
/// or by explicitly setting it back. Because this requires root,
/// all commands are run via osascript with administrator privileges.
///
/// Zoom ties device identity partly to MAC address. Spoofing it
/// presents ZoomFixer as a "fresh" device, which can clear
/// server-side error-1132 blocks that are MAC-keyed.
final class MacSpoofService: ObservableObject {
    @Published private(set) var isSpoofing = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var originalMAC: String = ""
    @Published private(set) var currentMAC: String = ""
    @Published private(set) var spoofedInterface: String = ""

    private let shell = ShellExecutor()

    // MARK: - Public API

    /// Discover the primary active interface and its current MAC.
    func detectInterface() async {
        let iface = await primaryInterface() ?? "en0"
        let mac = await readMAC(for: iface) ?? "unknown"
        await MainActor.run {
            self.spoofedInterface = iface
            self.originalMAC = mac
            self.currentMAC = mac
            self.statusMessage = "Detected interface \(iface) — MAC: \(mac)"
        }
    }

    /// Spoof to a randomly generated locally-administered unicast MAC.
    func spoofRandom() async {
        guard !isSpoofing else { return }
        await MainActor.run { self.isSpoofing = true; self.statusMessage = "Generating random MAC..." }

        let iface = spoofedInterface.isEmpty ? "en0" : spoofedInterface
        let newMAC = randomLocalMAC()

        await MainActor.run { self.statusMessage = "Setting MAC \(newMAC) on \(iface)..." }

        do {
            try await applyMAC(newMAC, to: iface)
            let confirmed = await readMAC(for: iface) ?? newMAC
            await MainActor.run {
                self.currentMAC = confirmed
                self.statusMessage = "MAC spoofed to \(confirmed) on \(iface)"
                self.isSpoofing = false
            }
        } catch {
            await MainActor.run {
                self.statusMessage = "Spoof failed: \(error.localizedDescription)"
                self.isSpoofing = false
            }
        }
    }

    /// Restore the original hardware MAC by cycling the interface.
    func restoreOriginal() async {
        guard !isSpoofing else { return }
        await MainActor.run { self.isSpoofing = true; self.statusMessage = "Restoring original MAC..." }

        let iface = spoofedInterface.isEmpty ? "en0" : spoofedInterface

        do {
            // Bring interface down, then up — macOS reloads the burned-in MAC
            try await shell.run(
                "ifconfig \(iface) down && sleep 1 && ifconfig \(iface) up",
                requireAdmin: true
            )
            let restored = await readMAC(for: iface) ?? originalMAC
            await MainActor.run {
                self.currentMAC = restored
                self.statusMessage = "MAC restored to \(restored) on \(iface)"
                self.isSpoofing = false
            }
        } catch {
            await MainActor.run {
                self.statusMessage = "Restore failed: \(error.localizedDescription)"
                self.isSpoofing = false
            }
        }
    }

    // MARK: - Internals

    private func applyMAC(_ mac: String, to iface: String) async throws {
        // Must bring interface down first, set MAC, then bring back up
        let cmd = "ifconfig \(iface) down && ifconfig \(iface) ether \(mac) && ifconfig \(iface) up"
        try await shell.run(cmd, requireAdmin: true)
    }

    private func readMAC(for iface: String) async -> String? {
        let result = try? await shell.run("ifconfig \(iface) | awk '/ether/{print $2}'")
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func primaryInterface() async -> String? {
        // Find the interface with the default IPv4 route
        let result = try? await shell.run(
            "route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -1"
        )
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Generates a random locally-administered unicast MAC.
    /// Bit 1 of byte 0 = 1 (locally administered), bit 0 = 0 (unicast).
    private func randomLocalMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE   // locally administered, unicast
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
