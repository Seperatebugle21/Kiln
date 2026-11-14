import SwiftUI

@main
struct KilnApp: App {
    @State private var projects: ProjectStore
    @State private var builds: BuildCoordinator
    @State private var assistant: AssistantSession

    init() {
        let projects = ProjectStore()
        let builds = BuildCoordinator()
        _projects = State(initialValue: projects)
        _builds = State(initialValue: builds)
        _assistant = State(initialValue: AssistantSession(projects: projects, builds: builds))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(projects)
                .environment(builds)
                .environment(assistant)
                .task { projects.restoreLastProject() }
        }
    }
}

struct RootView: View {
    @Environment(ProjectStore.self) private var projects

    var body: some View {
        Group {
            if projects.root != nil {
                WorkspaceView()
            } else {
                WelcomeView()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { projects.errorMessage != nil },
                set: { if !$0 { projects.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(projects.errorMessage ?? "")
        }
    }
}
