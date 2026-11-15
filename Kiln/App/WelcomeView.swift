import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(ProjectStore.self) private var projects
    @State private var xcodeProjectNeedingFolder: URL?
    @State private var showsSettings = false
    @State private var showsClone = false
    @State private var localProjects: [URL] = []
    @State private var pendingDeletion: URL?
    @State private var showsNewProject = false

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
                        DocumentPicker.present(contentTypes: DocumentPicker.projectTypes) { url in
                            handlePickedProject(url)
                        }
                    } label: {
                        Label("Open Project…", systemImage: "folder")
                    }
                    Button {
                        showsClone = true
                    } label: {
                        Label("Clone from GitHub…", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showsNewProject = true
                    } label: {
                        Label("New Project…", systemImage: "plus.square.on.square")
                    }
                } footer: {
                    Text("Open a project folder, a .swiftpm package or an .xcodeproj from the Files app. Kiln copies it into its own folder (On My iPhone › Kiln › Projects). For an Xcode project, picking the folder that contains it is quickest.")
                }

                if !projects.recentProjects.isEmpty {
                    Section("Recent") {
                        ForEach(projects.recentProjects) { recent in
                            Button {
                                projects.openRecent(recent)
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(recent.name)
                                        Text(recent.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                } icon: {
                                    Image(systemName: "clock")
                                }
                            }
                            .swipeActions {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    projects.forgetRecent(recent)
                                }
                            }
                        }
                    }
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
            .overlay {
                if let name = projects.importingName {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Copying \(name) into Kiln…")
                            .font(.headline)
                        Text("Kiln works on its own copy, so the project always reopens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(32)
                }
            }
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
            .sheet(isPresented: $showsClone) {
                CloneSheet()
            }
            .sheet(isPresented: $showsNewProject) {
                NewProjectSheet()
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
                        // Start in the folder that holds the .xcodeproj, so one tap on Open is enough.
                        // Wait for the alert to go away, or there is nothing to present from.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            DocumentPicker.present(contentTypes: [.folder], directoryURL: project.deletingLastPathComponent()) { url in
                                projects.grantFolder(url, for: project)
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("iOS only gives Kiln access to what you pick, and the source files of \(xcodeProjectNeedingFolder?.lastPathComponent ?? "this project") are next to it. Choose the folder that contains it. Kiln remembers that folder, so tip: pick a folder higher up (one that holds all your projects) and Kiln will not ask again.")
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

    private func handlePickedProject(_ url: URL) {
        if ["xcodeproj", "xcworkspace"].contains(url.pathExtension) {
            // Access covers only the picked item, and the sources live next to the .xcodeproj.
            // Kiln opens the folder directly when it already has access to it; otherwise it asks,
            // once the picker has gone away.
            if projects.openXcodeProject(url) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                xcodeProjectNeedingFolder = url
            }
        } else {
            projects.open(url)
        }
    }
}

/// Name a new project and pick a template.
struct NewProjectSheet: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template: ProjectTemplate = .helloWorld
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project Name", text: $name)
                        .focused($nameFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                } footer: {
                    if !trimmedName.isEmpty {
                        Text("The app type will be named \(ProjectTemplate.typeName(for: trimmedName))App.")
                    }
                }
                Section("Template") {
                    ForEach(ProjectTemplate.allCases) { option in
                        Button {
                            template = option
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.systemImage)
                                    .font(.title3)
                                    .frame(width: 32)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .foregroundStyle(.primary)
                                    Text(option.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if option == template {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = trimmedName
                        let template = template
                        dismiss()
                        projects.createProject(named: name, template: template)
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
