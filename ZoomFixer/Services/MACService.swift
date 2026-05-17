import Foundation
import Combine

/// Manages temporary MAC address spoofing on macOS for testing Zoom
/// fresh-device fingerprinting (useful when Zoom bans a device MAC).
///
/// On Apple Silicon and Intel Macs the MAC can be temporarily changed
/// using `ifconfig en0 ether <new-mac>` with admin privileges.
/// The change is NOT persistent — it reverts on reboot or when the
/// interface is cycled. This service remembers the original MAC so it
/// can restore it on demand.
final class MACService: ObservableObject {
    @Published private(set) var originalMAC: String = ""
    @Published private(set) var currentMAC: String = ""
    @Published private(set) var isSpoofed: Bool = false
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var statusMessage: String = "Ready"
    @Published private(set) var logs: [String] = []

    private let shell = ShellExecutor()
    private let interface: String

    init(interface: String = "en0") {
        self.interface = interface
    }

    // MARK: - Public API

    /// Read the current MAC from the interface.
    func refresh() {
        Task { await _refresh() }
    }

    /// Spoof to a random locally-administered unicast MAC address.
    func spoofRandom() {
        guard !isWorking else { return }
        let mac = MACService.randomLocalMAC()
        Task { await _setMAC(mac, label: "random") }
    }

    /// Spoof to a specific MAC address string (format: aa:bb:cc:dd:ee:ff).
    func spoof(to mac: String) {
        guard !isWorking, MACService.isValid(mac: mac) else {
            Task { @MainActor in self.statusMessage = "Invalid MAC format (use aa:bb:cc:dd:ee:ff)" }
            return
        }
        Task { await _setMAC(mac, label: "custom") }
    }

    /// Restore the original MAC recorded at first read.
    func restore() {
        guard !isWorking, !originalMAC.isEmpty else { return }
        Task { await _setMAC(originalMAC, label: "original"); await _markRestored() }
    }

    // MARK: - Internals

    @MainActor private func _markRestored() { isSpoofed = false }

    private func _refresh() async {
        let mac = await readMAC()
        await MainActor.run {
            self.currentMAC = mac
            if self.originalMAC.isEmpty { self.originalMAC = mac }
            self.statusMessage = mac.isEmpty ? "Could not read MAC" : "MAC: \(mac)"
        }
    }

    private func _setMAC(_ mac: String, label: String) async {
        await MainActor.run { self.isWorking = true; self.statusMessage = "Applying \(label) MAC..." }
        append("[mac] Setting \(interface) to \(mac) (\(label))")

        do {
            // Bring interface down, change MAC, bring back up
            let cmd = """
            ifconfig \(interface) down
            ifconfig \(interface) ether \(mac)
            ifconfig \(interface) up
            """
            try await shell.run(cmd, requireAdmin: true)
            let verified = await readMAC()
            if verified.lowercased() == mac.lowercased() {
                append("[mac] ✅ MAC changed to \(verified)")
                await MainActor.run {
                    self.currentMAC = verified
                    self.isSpoofed = (verified.lowercased() != self.originalMAC.lowercased())
                    self.statusMessage = self.isSpoofed
                        ? "Spoofed: \(verified) (original: \(self.originalMAC))"
                        : "Restored: \(verified)"
                }
            } else {
                append("[mac][warn] Requested \(mac) but interface reports \(verified).")
                append("[mac][warn] Some Apple Silicon NICs ignore MAC changes — reboot into Recovery may be needed.")
                await MainActor.run {
                    self.currentMAC = verified
                    self.statusMessage = "Change may not have applied (NIC: \(verified))"
                }
            }
        } catch {
            append("[mac][error] \(error.localizedDescription)")
            await MainActor.run { self.statusMessage = "Error: \(error.localizedDescription)" }
        }

        await MainActor.run { self.isWorking = false }
    }

    private func readMAC() async -> String {
        let res = try? await shell.run(
            "ifconfig \(interface) 2>/dev/null | awk '/ether/{print $2}'",
            allowFailure: true
        )
        return res?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @MainActor private func append(_ msg: String) {
        logs.append(msg)
    }

    // MARK: - Helpers

    /// Generate a random locally-administered unicast MAC.
    /// Bit 1 of octet 0 = 1 (locally administered), bit 0 = 0 (unicast).
    static func randomLocalMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFE) | 0x02  // locally administered, unicast
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    static func isValid(mac: String) -> Bool {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
}
