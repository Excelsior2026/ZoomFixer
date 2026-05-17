import Foundation
import Network

/// Tests reachability of Zoom's signalling and relay endpoints.
final class NetworkProbeService {

    struct ProbeResult {
        let host: String
        let port: UInt16
        let proto: String
        let reachable: Bool
        let latencyMs: Double?
    }

    /// TCP endpoints critical for Zoom error-1132 resolution.
    private let tcpEndpoints: [(host: String, port: UInt16)] = [
        ("zoom.us",              443),
        ("us04web.zoom.us",      443),
        ("us02web.zoom.us",      443),
        ("us04ws.zoom.us",       443),
        ("controlplane.zoom.us", 443)
    ]

    /// UDP ports used by Zoom's media relay (STUN/RTP).
    private let udpPorts: [UInt16] = [3478, 3479, 8801, 8802]
    private let stunHost = "us04stun1.zoom.us"

    func probeAll(logger: @escaping (LogEntry) -> Void) async -> [ProbeResult] {
        var results: [ProbeResult] = []

        logger(LogEntry(level: .info, category: "probe", message: "Starting endpoint reachability tests..."))

        await withTaskGroup(of: ProbeResult.self) { group in
            for ep in tcpEndpoints {
                group.addTask {
                    await self.probeTCP(host: ep.host, port: ep.port, logger: logger)
                }
            }
            for result in await group {
                results.append(result)
            }
        }

        // UDP probes (sequential — UDP is fire-and-check via NWConnection)
        for port in udpPorts {
            let r = await probeUDP(host: stunHost, port: port, logger: logger)
            results.append(r)
        }

        let blocked = results.filter { !$0.reachable }
        if blocked.isEmpty {
            logger(LogEntry(level: .info, category: "probe", message: "All Zoom endpoints reachable ✓"))
        } else {
            for b in blocked {
                logger(LogEntry(level: .warn, category: "probe",
                    message: "BLOCKED: \(b.host):\(b.port) (\(b.proto))"))
            }
        }

        return results
    }

    // MARK: - TCP

    private func probeTCP(host: String, port: UInt16, logger: @escaping (LogEntry) -> Void) async -> ProbeResult {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let start = Date()
            var resumed = false

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Date().timeIntervalSince(start) * 1000
                    logger(LogEntry(level: .info, category: "probe",
                        message: "TCP \(host):\(port) OK (\(String(format: "%.0f", ms))ms)"))
                    if !resumed { resumed = true; connection.cancel()
                        continuation.resume(returning: ProbeResult(host: host, port: port, proto: "TCP", reachable: true, latencyMs: ms))
                    }
                case .failed(let err):
                    logger(LogEntry(level: .warn, category: "probe",
                        message: "TCP \(host):\(port) FAILED: \(err.localizedDescription)"))
                    if !resumed { resumed = true; connection.cancel()
                        continuation.resume(returning: ProbeResult(host: host, port: port, proto: "TCP", reachable: false, latencyMs: nil))
                    }
                default: break
                }
            }

            connection.start(queue: .global())

            // Timeout after 6s
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if !resumed {
                    resumed = true
                    connection.cancel()
                    logger(LogEntry(level: .warn, category: "probe",
                        message: "TCP \(host):\(port) TIMEOUT"))
                    continuation.resume(returning: ProbeResult(host: host, port: port, proto: "TCP", reachable: false, latencyMs: nil))
                }
            }
        }
    }

    // MARK: - UDP

    private func probeUDP(host: String, port: UInt16, logger: @escaping (LogEntry) -> Void) async -> ProbeResult {
        return await withCheckedContinuation { continuation in
            let params = NWParameters.udp
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: params
            )
            let start = Date()
            var resumed = false

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send a minimal STUN binding request
                    let stunBinding = Data([
                        0x00,0x01,0x00,0x00,
                        0x21,0x12,0xA4,0x42,
                        0x00,0x00,0x00,0x00,
                        0x00,0x00,0x00,0x00,
                        0x00,0x00,0x00,0x00
                    ])
                    connection.send(content: stunBinding, completion: .idempotent)
                    let ms = Date().timeIntervalSince(start) * 1000
                    logger(LogEntry(level: .info, category: "probe",
                        message: "UDP \(host):\(port) sent probe (\(String(format: "%.0f", ms))ms)"))
                    if !resumed { resumed = true; connection.cancel()
                        continuation.resume(returning: ProbeResult(host: host, port: port, proto: "UDP", reachable: true, latencyMs: ms))
                    }
                case .failed(let err):
                    logger(LogEntry(level: .warn, category: "probe",
                        message: "UDP \(host):\(port) FAILED: \(err.localizedDescription)"))
                    if !resumed { resumed = true; connection.cancel()
                        continuation.resume(returning: ProbeResult(host: host, port: port, proto: "UDP", reachable: false, latencyMs: nil))
                    }
                default: break
                }
            }

            connection.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if !resumed {
                    resumed = true
                    connection.cancel()
                    logger(LogEntry(level: .warn, category: "probe",
                        message: "UDP \(host):\(port) TIMEOUT (may be filtered)"))
                    continuation.resume(returning: ProbeResult(host: host, port: port, proto: "UDP", reachable: false, latencyMs: nil))
                }
            }
        }
    }
}
