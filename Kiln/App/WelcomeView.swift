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
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    actions
                    projectSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.immediately)
            .refreshable { reload() }
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
        HStack(spacing: 16) {
            Image("KilnLogo")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Kiln")
                    .font(.largeTitle.bold())
                Text("Build and run SwiftUI apps on your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            ActionTile(title: "New", subtitle: "From a template", systemImage: "plus", prominent: true) {
                showsNewProject = true
            }
            ActionTile(title: "Open", subtitle: "From Files", systemImage: "folder") {
                DocumentPicker.present(contentTypes: DocumentPicker.projectTypes) { url in
                    handlePickedProject(url)
                }
            }
            ActionTile(title: "Clone", subtitle: "From GitHub", systemImage: "arrow.down.circle") {
                showsClone = true
            }
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Projects")
                    .font(.title2.bold())
                Spacer()
                if !summaries.isEmpty {
                    Text("\(summaries.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if summaries.count > 5 {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search projects", text: $search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if summaries.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("No projects match \u{201C}\(search)\u{201D}.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { project in
                        ProjectCard(project: project) {
                            projects.open(project.url)
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
                }
            }

            Text("Projects live in Files › On My iPhone › Kiln › Projects. Projects you open from elsewhere are copied there, so they always reopen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("No projects yet")
                .font(.headline)
            Text("Start from a template, or open a Swift package, a .swiftpm or an Xcode project.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create a Project") { showsNewProject = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    var kindLabel: String {
        url.pathExtension == "swiftpm" ? "App Playground" : kind.rawValue
    }
}

private struct ActionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(prominent ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .opacity(0.75)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .background(
                prominent ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) project, \(subtitle)")
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: project.systemImage)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
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
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Scales a card down slightly while it is pressed.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
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
