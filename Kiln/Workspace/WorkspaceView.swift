import SwiftUI

struct WorkspaceView: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(BuildCoordinator.self) private var builds
    @Environment(SyncController.self) private var sync
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsAssistant = false
    @State private var showsBuildLog = false
    @State private var showsSettings = false
    @State private var showsCommitSheet = false
    @State private var showsConsole = false
    @State private var runningApp: RunningApp?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// On iPhone only one column shows at a time; opening a file switches to the editor.
    @State private var compactColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            FileTreeView()
                .navigationTitle(projects.name)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Console", systemImage: "terminal") { showsConsole = true }
                            Button("Settings", systemImage: "gearshape") { showsSettings = true }
                            Button("Close Project", systemImage: "xmark.square") { projects.close() }
                        } label: {
                            Label("Project", systemImage: "ellipsis.circle")
                        }
                    }
                    if sync.state != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            SyncMenu(showsCommitSheet: $showsCommitSheet)
                        }
                    }
                }
        } detail: {
            EditorPane()
                .toolbar { workspaceToolbar }
        }
        .inspector(isPresented: $showsAssistant) {
            AssistantView()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
        }
        .sheet(isPresented: $showsBuildLog) {
            BuildLogView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showsCommitSheet) {
            CommitSheet()
        }
        .sheet(isPresented: $showsConsole) {
            ConsoleView()
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $runningApp) { app in
            RunnerView(controller: app.controller, appName: projects.name) {
                // Restart: close the app, then build and run again once the cover is gone.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    run()
                }
            }
        }
        .onChange(of: projects.fileOpenCount) {
            compactColumn = .detail
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { projects.save() }
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                run()
            } label: {
                if builds.phase == .building {
                    ProgressView()
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .disabled(builds.phase == .building)

            Button {
                showsBuildLog = true
            } label: {
                Label("Build Log", systemImage: buildStatusImage)
            }
            .foregroundStyle(buildStatusColor)

            Button {
                showsAssistant.toggle()
            } label: {
                Label("Claude", systemImage: "sparkles")
            }
        }
    }

    private var buildStatusImage: String {
        switch builds.phase {
        case .failed: return "xmark.octagon"
        case .succeeded: return "checkmark.seal"
        default: return "list.bullet.rectangle"
        }
    }

    private var buildStatusColor: Color {
        switch builds.phase {
        case .failed: return .red
        case .succeeded: return .green
        default: return .primary
        }
    }

    private func run() {
        Task {
            guard await builds.build(projects), let product = builds.product else {
                showsBuildLog = true
                return
            }
            do {
                // Capture output from the start, including what the app prints while it launches.
                RunConsole.shared.start()
                runningApp = RunningApp(controller: try AppRunner.load(product))
            } catch {
                RunConsole.shared.stop()
                projects.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RunningApp: Identifiable {
    let id = UUID()
    let controller: UIViewController
}

struct EditorPane: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(BuildCoordinator.self) private var builds
    /// Syntax errors found while typing (Swift files), checked shortly after the last keystroke.
    @State private var liveErrors: [BuildDiagnostic] = []
    @State private var focusLine: Int?

    var body: some View {
        if let file = projects.selectedFile {
            let path = projects.relativePath(of: file)
            let errors = (liveErrors + builds.diagnostics.filter { $0.severity == .error && $0.file == path })
                .sorted { $0.line < $1.line }
            CodeEditor(
                text: Binding(get: { projects.buffer }, set: { projects.updateBuffer($0) }),
                highlightsSwift: file.pathExtension == "swift",
                errorLines: Dictionary(errors.map { ($0.line, $0.message) }, uniquingKeysWith: { first, _ in first }),
                focusLine: $focusLine
            )
            .id(file)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let first = errors.first {
                    ErrorBanner(diagnostic: first, count: errors.count) { focusLine = first.line }
                }
            }
            .task(id: projects.buffer) {
                guard file.pathExtension == "swift" else {
                    liveErrors = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let source = SourceFile(path: path, text: projects.buffer)
                let found = await Task.detached(priority: .utility) { SyntaxChecker.check(source) }.value
                guard !Task.isCancelled else { return }
                liveErrors = found.filter { $0.severity == .error }
            }
            .navigationTitle(file.lastPathComponent + (projects.isDirty ? " •" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Save", systemImage: "square.and.arrow.down") { projects.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!projects.isDirty)
                }
            }
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Choose a file in the sidebar."))
        }
    }
}

/// The first error in the open file; tap to jump to its line.
private struct ErrorBanner: View {
    let diagnostic: BuildDiagnostic
    let count: Int
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Line \(diagnostic.line)" + (count > 1 ? " · \(count) errors" : ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(diagnostic.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .buttonStyle(.plain)
    }
}
