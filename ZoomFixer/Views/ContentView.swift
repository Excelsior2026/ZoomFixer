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
                Button(action: viewModel.prepareFixPreview) {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                        Text(viewModel.isRunning ? "Working..." : "Review Fix...")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRunning || viewModel.isPreparingPreview || viewModel.isConfirmationPending)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }

            if viewModel.isPreparingPreview {
                ProgressView("Building change preview (no changes yet)...")
            } else if viewModel.isConfirmationPending {
                GroupBox("Preflight preview — nothing has been changed") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Review the changes below, then confirm or cancel. No repair runs until you confirm.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if viewModel.previewItems.isEmpty {
                            Text("No state changes detected. The repair will still download and install Zoom.")
                                .font(.caption)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(viewModel.previewItems) { item in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(item.kind.rawValue): \(item.target)")
                                                .font(.system(size: 12, weight: .semibold))
                                            Text(item.detail)
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                                .textSelection(.enabled)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(4)
                            }
                            .frame(maxHeight: 200)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
                        }

                        HStack(spacing: 12) {
                            Button("Confirm and Run") { viewModel.confirmFix() }
                                .buttonStyle(.borderedProminent)
                            Button("Cancel") { viewModel.cancelPreview() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(8)
                }
            }

            if viewModel.isRunning {
                HStack(spacing: 12) {
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

                    Button("Cancel Repair") { viewModel.cancelFix() }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.cancellationRequested)
                }

                if viewModel.cancellationRequested {
                    Text("Cancelling: the current command is being stopped. Steps already completed are not automatically rolled back.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Activity log")
                    .font(.headline)
                LogView(entries: viewModel.logs)
                    .frame(maxHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            }

            if let outcome = viewModel.lastOutcome {
                GroupBox("Last run outcome") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(outcome.state.rawValue)
                                .font(.headline)
                            Spacer()
                            Button("Dismiss") { viewModel.clearOutcome() }
                                .buttonStyle(.borderless)
                        }
                        Text(outcome.summary)
                            .font(.caption)
                            .textSelection(.enabled)

                        if !outcome.failures.isEmpty {
                            Text("Failed steps:")
                                .font(.caption)
                                .bold()
                            ForEach(outcome.failures) { result in
                                Text("• \(result.title): \(result.detail)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .textSelection(.enabled)
                            }
                        }

                        if !outcome.warnings.isEmpty {
                            Text("Advisory warnings:")
                                .font(.caption)
                                .bold()
                            ForEach(outcome.warnings, id: \.self) { warning in
                                Text("• \(warning)")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .textSelection(.enabled)
                            }
                        }

                        if !outcome.skipped.isEmpty {
                            Text("Not completed:")
                                .font(.caption)
                                .bold()
                            ForEach(outcome.skipped) { result in
                                Text("• \(result.title) — \(result.state.rawValue): \(result.detail)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                }
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
