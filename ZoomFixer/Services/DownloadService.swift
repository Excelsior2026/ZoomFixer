import Foundation

final class DownloadService {
    private let zoomURL = URL(string: "https://zoom.us/client/latest/Zoom.pkg")!

    func downloadZoomInstaller(
        progressHandler: ((Double) -> Void)? = nil,
        logHandler: ((String) -> Void)? = nil
    ) async throws -> URL {
        logHandler?("Downloading latest Zoom package...")

        var request = URLRequest(url: zoomURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validate(response: response)

        let expectedSize = response.expectedContentLength
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomInstaller-\(UUID().uuidString).pkg")

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var received: Int64 = 0
        for try await byte in bytes {
            handle.write(Data([byte]))
            received += 1

            if expectedSize > 0 {
                progressHandler?(Double(received) / Double(expectedSize))
            }
        }

        progressHandler?(1.0)
        logHandler?("Installer saved to \(destination.path)")
        return destination
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ZoomFixErrorDescription("Download failed with status \(http.statusCode)")
        }
    }
}

struct ZoomFixErrorDescription: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
