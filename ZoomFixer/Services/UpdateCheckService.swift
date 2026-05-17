import Foundation
import Combine
import AppKit

/// Checks GitHub Releases for a newer version of ZoomFixer and
/// surfaces a banner in the UI when one is available.
final class UpdateCheckService: ObservableObject {
    @Published private(set) var latestVersion: String = ""
    @Published private(set) var updateAvailable: Bool = false
    @Published private(set) var releaseURL: URL? = nil
    @Published private(set) var isChecking: Bool = false

    private let repo = "Excelsior2026/ZoomFixer"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { Task { @MainActor in self.isChecking = false } }
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
            else { return }

            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String
            else { return }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let isNewer = latest.compare(currentVersion, options: .numeric) == .orderedDescending

            await MainActor.run {
                self.latestVersion = latest
                self.updateAvailable = isNewer
                self.releaseURL = URL(string: htmlURL)
            }
        }
    }

    func openReleasePage() {
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
    }
}
