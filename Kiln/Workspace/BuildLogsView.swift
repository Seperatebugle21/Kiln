import SwiftUI
import UIKit

/// Saved logs of recent builds, including builds that crashed Kiln, and the compiler's last output.
struct BuildLogsView: View {
    @State private var entries: [BuildLogStore.Entry] = []

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LogFileView(title: "Compiler Output", url: LocalToolchainBackend.compilerLogURL)
                } label: {
                    Label("Last Compiler Output", systemImage: "terminal")
                }
            } footer: {
                Text("What the Swift or C compiler printed last, also after a crash.")
            }

            Section {
                if entries.isEmpty {
                    Text("Logs appear here after you build a project.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    NavigationLink {
                        LogFileView(title: entry.project, url: entry.url)
                    } label: {
                        LogEntryRow(entry: entry)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { try? FileManager.default.removeItem(at: entries[index].url) }
                    entries.remove(atOffsets: offsets)
                }
            } header: {
                Text("Recent Builds")
            } footer: {
                Text("The last \(BuildLogStore.keep) builds. Also in Files › On My iPhone › Kiln › Build Logs.")
            }
        }
        .navigationTitle("Build Logs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = BuildLogStore.entries() }
        .refreshable { entries = BuildLogStore.entries() }
    }
}

private struct LogEntryRow: View {
    let entry: BuildLogStore.Entry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.project)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(label)
                    Text("·")
                    Text(entry.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch entry.result {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .crashed: return "exclamationmark.triangle.fill"
        case .running: return "hourglass"
        }
    }

    private var color: Color {
        switch entry.result {
        case .succeeded: return .green
        case .failed: return .red
        case .crashed: return .orange
        case .running: return .secondary
        }
    }

    private var label: String {
        switch entry.result {
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .crashed: return "Crashed"
        case .running: return "In progress"
        }
    }
}

/// A log file as selectable monospaced text, with Copy and Share.
struct LogFileView: View {
    let title: String
    let url: URL
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "Empty." : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(.systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: url)
            }
        }
        .onAppear {
            // Very long logs are cut to their end, which is where errors are.
            let full = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text = full.count > 200_000 ? "…\n" + String(full.suffix(200_000)) : full
        }
    }
}
