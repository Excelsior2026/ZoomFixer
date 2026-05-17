import Foundation

/// Checks GitHub Releases for a newer version of ZoomFixer.
final class UpdateChecker: ObservableObject {
    @Published private(set) var latestVersion: String = ""
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var releaseURL: URL? = nil

    private let apiURL = URL(string: "https://api.github.com/repos/Excelsior2026/ZoomFixer/releases/latest")!

    func check() {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: apiURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String
            else { return }

            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            let updateAvailable = tag.trimmingCharacters(in: .init(charactersIn: "v")) > current

            await MainActor.run {
                self.latestVersion = tag
                self.isUpdateAvailable = updateAvailable
                self.releaseURL = URL(string: htmlURL)
            }
        }
    }
}
