import SwiftUI

@main
struct ZoomFixerApp: App {
    @StateObject private var service = ZoomFixService()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: service)
                .frame(minWidth: 640, minHeight: 520)
        }
    }
}
