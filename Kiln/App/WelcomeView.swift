import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(ProjectStore.self) private var projects
    @State private var xcodeProjectNeedingFolder: URL?
    @State private var showsSettings = false
    @State private var showsClone = false
    @State private var showsNewProject = false
    @State private var summaries: [ProjectSummary] = []
    @State private var search = ""
    @State private var pendingDeletion: ProjectSummary?
    @State private var renaming: ProjectSummary?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    ActionRow(title: "New Project", systemImage: "plus", color: .accentColor) {
                        showsNewProject = true
                    }
                    ActionRow(title: "Open from Files", systemImage: "folder.fill", color: .blue) {
                        DocumentPicker.present(contentTypes: DocumentPicker.projectTypes) { url in
                            handlePickedProject(url)
                        }
                    }
                    ActionRow(title: "Clone from GitHub", systemImage: "arrow.down", color: Color(white: 0.2)) {
                        showsClone = true
                    }
                }

                Section {
                    if summaries.isEmpty {
                        Text("Your projects will appear here.")
                            .foregroundStyle(.secondary)
                    } else if filtered.isEmpty {
                        Text("No projects match \u{201C}\(search)\u{201D}.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { project in
                        Button {
                            projects.open(project.url)
                        } label: {
                            ProjectRow(project: project)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = project }
                            Button("Rename", systemImage: "pencil") {
                                newName = project.name
                                renaming = project
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") { projects.open(project.url) }
                            Button("Rename", systemImage: "pencil") {
                                newName = project.name
                                renaming = project
                            }
                            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(project) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = project }
                        }
                    }
                } header: {
                    Text("Projects")
                } footer: {
                    Text("Stored in Files › On My iPhone › Kiln. Projects you open from elsewhere are copied here.")
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search projects")
            .refreshable { reload() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .overlay { importOverlay }
            .onAppear(perform: reload)
            .onChange(of: projects.importingName) { reload() }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .sheet(isPresented: $showsClone) { CloneSheet() }
            .sheet(isPresented: $showsNewProject) { NewProjectSheet() }
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
                Text("iOS only gives Kiln access to what you pick, and the source files of \(xcodeProjectNeedingFolder?.lastPathComponent ?? "this project") are next to it. Choose the folder that contains it.")
            }
            .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                Button("Rename") {
                    if let project = renaming { rename(project, to: newName) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete \(pendingDeletion?.name ?? "")?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Project", role: .destructive) {
                    if let project = pendingDeletion {
                        try? FileManager.default.removeItem(at: project.url)
                        reload()
                    }
                    pendingDeletion = nil
                }
            } message: {
                Text("The project and its files are removed from this iPhone.")
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image("KilnLogo")
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.25), radius: 16, y: 8)
                .accessibilityHidden(true)
            Text("Kiln")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Build and run SwiftUI apps on your iPhone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var importOverlay: some View {
        if let name = projects.importingName {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Copying \(name) into Kiln…")
                    .font(.headline)
                Text("Kiln works on its own copy, so the project always reopens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(32)
        }
    }

    // MARK: Data

    private var filtered: [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return summaries }
        return summaries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func reload() {
        summaries = projects.localProjects().map(ProjectSummary.init)
    }

    private func rename(_ project: ProjectSummary, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !cleaned.isEmpty, cleaned != project.name else { return }
        let fileExtension = project.url.pathExtension
        let target = project.url.deletingLastPathComponent()
            .appendingPathComponent(fileExtension.isEmpty ? cleaned : "\(cleaned).\(fileExtension)")
        do {
            try FileManager.default.moveItem(at: project.url, to: target)
        } catch {
            projects.errorMessage = "Could not rename \(project.name): \(error.localizedDescription)"
        }
        reload()
    }

    private func duplicate(_ project: ProjectSummary) {
        let folder = project.url.deletingLastPathComponent()
        let fileExtension = project.url.pathExtension
        var index = 1
        var target: URL
        repeat {
            let name = index == 1 ? "\(project.name) copy" : "\(project.name) copy \(index)"
            target = folder.appendingPathComponent(fileExtension.isEmpty ? name : "\(name).\(fileExtension)")
            index += 1
        } while FileManager.default.fileExists(atPath: target.path)
        do {
            try FileManager.default.copyItem(at: project.url, to: target)
        } catch {
            projects.errorMessage = "Could not duplicate \(project.name): \(error.localizedDescription)"
        }
        reload()
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

/// A project in Kiln's Projects folder, as shown on the start screen.
struct ProjectSummary: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let kind: ProjectKind
    let modified: Date?

    init(url: URL) {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        kind = ProjectDetector.kind(of: url)
        modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    var systemImage: String {
        if url.pathExtension == "swiftpm" { return "swift" }
        switch kind {
        case .xcodeProject: return "hammer.fill"
        case .swiftPackage: return "shippingbox.fill"
        case .folder: return "folder.fill"
        }
    }

    var color: Color {
        if url.pathExtension == "swiftpm" { return .orange }
        switch kind {
        case .xcodeProject: return .blue
        case .swiftPackage: return .brown
        case .folder: return .gray
        }
    }

    var kindLabel: String {
        url.pathExtension == "swiftpm" ? "App Playground" : kind.rawValue
    }
}

/// A rounded, colored icon like the ones in the Settings app.
private struct RowIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RowIcon(systemImage: systemImage, color: color)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(systemImage: project.systemImage, color: project.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(project.kindLabel)
                    if let modified = project.modified {
                        Text("·")
                        Text(modified, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
