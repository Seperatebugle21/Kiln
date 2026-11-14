import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(ProjectStore.self) private var projects
    @State private var picker: PickerRequest?
    @State private var xcodeProjectNeedingFolder: URL?
    @State private var showsSettings = false
    @State private var localProjects: [URL] = []
    @State private var pendingDeletion: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)
                        Text("Write, build and run SwiftUI apps on your iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        picker = .project
                    } label: {
                        Label("Open Project…", systemImage: "folder")
                    }
                    Button {
                        projects.createSampleProject()
                    } label: {
                        Label("New Sample Project", systemImage: "plus.square.on.square")
                    }
                } footer: {
                    Text("Open a project folder, a .swiftpm package or an .xcodeproj from the Files app.")
                }

                Section {
                    if localProjects.isEmpty {
                        Text("Projects you create appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(localProjects, id: \.self) { url in
                        Button {
                            projects.open(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "hammer")
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDeletion = url
                            }
                        }
                    }
                } header: {
                    Text("On This Device")
                } footer: {
                    Text("Also in the Files app under On My iPhone › Kiln › Projects.")
                }
            }
            .navigationTitle("Kiln")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .onAppear { localProjects = projects.localProjects() }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            .sheet(item: $picker) { request in
                DocumentPicker(contentTypes: request.contentTypes, directoryURL: request.directoryURL) { url in
                    handlePick(url, for: request)
                }
                .ignoresSafeArea()
            }
            .alert(
                "Choose the Project Folder",
                isPresented: Binding(
                    get: { xcodeProjectNeedingFolder != nil },
                    set: { if !$0 { xcodeProjectNeedingFolder = nil } }
                )
            ) {
                Button("Choose Folder") {
                    if let project = xcodeProjectNeedingFolder {
                        picker = .folderContaining(project)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("iOS only gives Kiln access to what you pick. To build \(xcodeProjectNeedingFolder?.lastPathComponent ?? "this project"), choose the folder that contains it and its source files.")
            }
            .confirmationDialog(
                "Delete \(pendingDeletion?.lastPathComponent ?? "")?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Project", role: .destructive) {
                    if let url = pendingDeletion {
                        try? FileManager.default.removeItem(at: url)
                        localProjects = projects.localProjects()
                    }
                    pendingDeletion = nil
                }
            }
        }
    }

    private func handlePick(_ url: URL, for request: PickerRequest) {
        picker = nil
        switch request {
        case .project where ["xcodeproj", "xcworkspace"].contains(url.pathExtension):
            // Access covers only the picked item, and the sources live next to the .xcodeproj.
            // Present the folder picker after this sheet has gone away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                xcodeProjectNeedingFolder = url
            }
        default:
            projects.open(url)
        }
    }
}

private enum PickerRequest: Identifiable {
    case project
    case folderContaining(URL)

    var id: String {
        switch self {
        case .project: return "project"
        case .folderContaining(let url): return "folder:" + url.path
        }
    }

    var contentTypes: [UTType] {
        switch self {
        case .project: return DocumentPicker.projectTypes
        case .folderContaining: return [.folder]
        }
    }

    var directoryURL: URL? {
        switch self {
        case .project: return nil
        case .folderContaining(let url): return url.deletingLastPathComponent()
        }
    }
}
