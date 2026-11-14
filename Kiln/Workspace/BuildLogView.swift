import SwiftUI

struct BuildLogView: View {
    @Environment(BuildCoordinator.self) private var builds
    @Environment(ProjectStore.self) private var projects
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !builds.diagnostics.isEmpty {
                    Section("Issues") {
                        ForEach(builds.diagnostics) { diagnostic in
                            Button {
                                open(diagnostic)
                            } label: {
                                DiagnosticRow(diagnostic: diagnostic)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Log") {
                    if builds.log.isEmpty {
                        Text("Press Run to build the project.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(builds.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Build")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func open(_ diagnostic: BuildDiagnostic) {
        guard let url = try? projects.resolve(diagnostic.file),
              FileManager.default.fileExists(atPath: url.path) else { return }
        projects.select(url)
        dismiss()
    }
}

private struct DiagnosticRow: View {
    let diagnostic: BuildDiagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message)
                    .font(.callout)
                Text("\(diagnostic.file):\(diagnostic.line):\(diagnostic.column)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch diagnostic.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch diagnostic.severity {
        case .error: return .red
        case .warning: return .yellow
        case .note: return .secondary
        }
    }
}
