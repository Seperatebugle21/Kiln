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
        .fullScreenCover(item: $runningApp) { app in
            RunnerView(controller: app.controller)
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
                runningApp = RunningApp(controller: try AppRunner.load(product))
            } catch {
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

    var body: some View {
        if let file = projects.selectedFile {
            CodeEditor(
                text: Binding(get: { projects.buffer }, set: { projects.updateBuffer($0) }),
                highlightsSwift: file.pathExtension == "swift"
            )
            .id(file)
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
