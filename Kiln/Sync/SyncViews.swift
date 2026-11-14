import SwiftUI

struct CloneSheet: View {
    @Environment(SyncController.self) private var sync
    @Environment(ProjectStore.self) private var projects
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var branch = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("owner/repository", text: $repository)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Branch (default branch if empty)", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("A link such as github.com/owner/repository works too.")
                }
                if !sync.hasToken {
                    Section {
                        Label("Add a GitHub token in Settings to clone private repositories and push changes.", systemImage: "key")
                            .font(.footnote)
                    }
                }
                if sync.isSyncing {
                    Section {
                        HStack {
                            ProgressView()
                            Text(sync.progress ?? "Cloning…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Clone from GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(sync.isSyncing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") {
                        Task {
                            if await sync.clone(repository, branch: branch, projects: projects) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(repository.isEmpty || sync.isSyncing)
                }
            }
        }
        .interactiveDismissDisabled(sync.isSyncing)
    }
}

struct CommitSheet: View {
    @Environment(SyncController.self) private var sync
    @Environment(ProjectStore.self) private var projects
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [LocalChange]?
    @State private var commitMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What changed?", text: $commitMessage, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("Commit Message")
                }
                Section {
                    if let changes {
                        if changes.isEmpty {
                            Text("No local changes.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(changes) { change in
                            HStack {
                                Text(change.kind.rawValue)
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(color(change.kind))
                                    .frame(width: 18)
                                Text(change.path)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } else {
                        ProgressView()
                    }
                } header: {
                    Text("Changes")
                } footer: {
                    if let state = sync.state {
                        Text("Commits to \(state.branch) on \(state.repositoryName).")
                    }
                }
                if sync.isSyncing {
                    Section {
                        HStack {
                            ProgressView()
                            Text(sync.progress ?? "Pushing…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Commit & Push")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(sync.isSyncing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Push") {
                        Task {
                            let text = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await sync.push(projects, message: text.isEmpty ? "Update from Kiln" : text) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(sync.isSyncing || (changes ?? []).isEmpty || !sync.hasToken)
                }
            }
            .task {
                changes = await sync.changes(in: projects)
            }
        }
        .interactiveDismissDisabled(sync.isSyncing)
    }

    private func color(_ kind: LocalChange.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        }
    }
}

/// The sync menu shown in the file list when the project is linked to GitHub.
struct SyncMenu: View {
    @Environment(SyncController.self) private var sync
    @Environment(ProjectStore.self) private var projects
    @Binding var showsCommitSheet: Bool
    @State private var confirmsDiscard = false

    var body: some View {
        Menu {
            if let state = sync.state {
                Section("\(state.repositoryName) · \(state.branch)") {
                    Button("Pull", systemImage: "arrow.down.circle") {
                        Task { await sync.pull(projects) }
                    }
                    Button("Commit & Push…", systemImage: "arrow.up.circle") {
                        showsCommitSheet = true
                    }
                    Button("Discard Local Changes…", systemImage: "arrow.uturn.backward", role: .destructive) {
                        confirmsDiscard = true
                    }
                }
            }
        } label: {
            if sync.isSyncing {
                ProgressView()
            } else {
                Label("GitHub", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(sync.isSyncing)
        .confirmationDialog("Discard local changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard and Pull", role: .destructive) {
                Task { await sync.pull(projects, overwriteLocal: true) }
            }
        } message: {
            Text("Every synced file is replaced by the latest version on GitHub. New files you added stay.")
        }
    }
}
