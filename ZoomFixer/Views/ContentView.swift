import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: ZoomFixService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ZoomFixer")
                    .font(.largeTitle).bold()
                Text("One-click repair for Zoom error 1132.")
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button(action: viewModel.startFix) {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                        Text(viewModel.isRunning ? "Working..." : "Fix Zoom 1132")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRunning)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }

            if viewModel.isRunning {
                if let progress = viewModel.progress {
                    ProgressView(value: progress, total: 1.0) {
                        Text(viewModel.progressLabel)
                    }
                    .progressViewStyle(.linear)
                } else {
                    ProgressView {
                        Text(viewModel.progressLabel)
                    }
                    .progressViewStyle(.linear)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Activity log")
                    .font(.headline)
                LogView(entries: viewModel.logs)
                    .frame(maxHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            }

            GroupBox("Sandbox Zoom (Docker)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run Zoom inside an isolated Linux container to appear as a fresh device. Requires Docker Desktop. Connect via browser (noVNC) at http://localhost:6080/vnc.html or VNC on localhost:5901.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        Button(action: viewModel.autoPrepareAndLaunchDockerSandbox) {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text(viewModel.isLaunchingDocker || viewModel.isInstallingDocker ? "Preparing..." : "One-click Sandbox")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isLaunchingDocker || viewModel.isRunning || viewModel.isInstallingDocker)

                        Button(action: viewModel.launchDockerSandbox) {
                            HStack {
                                Image(systemName: "shippingbox.fill")
                                Text(viewModel.isLaunchingDocker ? "Starting..." : "Launch Docker Sandbox")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLaunchingDocker || viewModel.isRunning || viewModel.isInstallingDocker)

                        Button(action: viewModel.checkDockerAvailability) {
                            Label("Re-check Docker", systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLaunchingDocker || viewModel.isInstallingDocker)

                        Button(action: viewModel.installDockerViaHomebrew) {
                            Label("Install via Homebrew", systemImage: "tray.and.arrow.down.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLaunchingDocker || viewModel.isInstallingDocker)

                        Button(action: viewModel.openDockerDownloadPage) {
                            Label("Install Docker", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLaunchingDocker || viewModel.isInstallingDocker)

                        if viewModel.isLaunchingDocker || viewModel.isInstallingDocker {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }

                    Text(viewModel.dockerStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                StatusIndicator(status: viewModel.statusKind)
                Text(viewModel.statusMessage)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(24)
    }
}

private struct LogView: View {
    let entries: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        Text(entry)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: entries.count) { _ in
                if let last = entries.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}

private struct StatusIndicator: View {
    let status: ZoomFixService.StatusKind

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 10, height: 10)
            .animation(.easeInOut(duration: 0.2), value: status)
    }
}

extension ZoomFixService.StatusKind {
    var color: Color {
        switch self {
        case .idle: return .gray
        case .running: return .blue
        case .success: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ZoomFixService())
            .frame(width: 720, height: 520)
    }
}
