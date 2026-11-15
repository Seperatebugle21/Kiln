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
            ZStack(alignment: .bottom) {
                EmberBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        topBar
                        greeting
                        if let latest = summaries.first {
                            ContinueCard(project: latest) { projects.open(latest.url) }
                                .contextMenu { menu(for: latest) }
                        }
                        if summaries.isEmpty {
                            emptyState
                        } else {
                            shelf
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }
                .scrollIndicators(.hidden)
                .refreshable { reload() }

                ActionDock(
                    new: { showsNewProject = true },
                    open: {
                        DocumentPicker.present(contentTypes: DocumentPicker.projectTypes) { url in
                            handlePickedProject(url)
                        }
                    },
                    clone: { showsClone = true }
                )
                .padding(.bottom, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.colorScheme, .dark)
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

    private var topBar: some View {
        HStack(spacing: 10) {
            Image("KilnLogo")
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text("Kiln")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.greeting())
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(red: 1, green: 0.78, blue: 0.6)], startPoint: .leading, endPoint: .trailing)
                )
            Text(summaries.isEmpty ? "Let's fire up your first app." : "What are we making today?")
                .font(.title3)
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Projects")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                NavigationLink {
                    AllProjectsView(summaries: summaries, open: { projects.open($0.url) }, menu: { menu(for: $0) }, reload: reload)
                } label: {
                    Text("See All \(summaries.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ember)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(Array(summaries.dropFirst().prefix(12))) { project in
                        ProjectTile(project: project) { projects.open(project.url) }
                            .contextMenu { menu(for: project) }
                    }
                    NewTile { showsNewProject = true }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "flame.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [.yellow, Color.ember, .red], startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: Color.ember.opacity(0.7), radius: 24)
                .symbolEffect(.breathe, options: .repeat(.continuous))
            Text("Nothing in the kiln yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Start from a template, or open a Swift package, an App Playground or an Xcode project.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func menu(for project: ProjectSummary) -> some View {
        Button("Open", systemImage: "arrow.up.forward.app") { projects.open(project.url) }
        Button("Rename", systemImage: "pencil") {
            newName = project.name
            renaming = project
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(project) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = project }
    }

    private static func greeting() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default: return "Late night?"
        }
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

extension Color {
    /// Kiln's warm orange.
    static let ember = Color(red: 0.95, green: 0.45, blue: 0.2)
}

/// A dark, warm background: a glow at the bottom and embers drifting up.
private struct EmberBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.05, blue: 0.04), Color(red: 0.04, green: 0.03, blue: 0.03)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.ember.opacity(0.45), Color.red.opacity(0.12), Color.clear],
                center: .bottom, startRadius: 10, endRadius: 520
            )
            RadialGradient(
                colors: [Color.orange.opacity(0.12), Color.clear],
                center: .topTrailing, startRadius: 0, endRadius: 360
            )
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        Self.drawEmbers(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private static func drawEmbers(in context: inout GraphicsContext, size: CGSize, time: Double) {
        for index in 0..<36 {
            let seed = Double(index) * 12.9898
            let speed = 0.03 + (sin(seed) + 1) * 0.02
            let progress = fract(time * speed + fract(seed * 0.618))
            let x = fract(sin(seed) * 43758.5453) * Double(size.width) + sin(time * 0.6 + seed) * 14
            let y = Double(size.height) * (1.05 - progress * 1.15)
            let radius = 1.2 + fract(seed * 0.37) * 2.2
            let opacity = sin(progress * Double.pi) * (0.35 + fract(seed * 0.73) * 0.5)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            let color = Color(red: 1, green: 0.6 + fract(seed) * 0.3, blue: 0.3).opacity(opacity)
            var ember = context
            ember.addFilter(.blur(radius: radius * 0.6))
            ember.fill(Circle().path(in: rect), with: .color(color))
        }
    }

    private static func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

/// The most recent project, big, with a button to continue.
private struct ContinueCard: View {
    let project: ProjectSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    ProjectGlyph(project: project, size: 54)
                    Spacer()
                    Text("CONTINUE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(project.kindLabel)
                        if let modified = project.modified {
                            Text("·")
                            Text(modified, format: .relative(presentation: .named))
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
                }
                HStack {
                    Label("Open Project", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.ember.gradient, in: Capsule())
                    Spacer()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(LinearGradient(colors: [project.color.opacity(0.35), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            }
            .shadow(color: project.color.opacity(0.25), radius: 30, y: 12)
        }
        .buttonStyle(SquishStyle())
    }
}

private struct ProjectTile: View {
    let project: ProjectSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ProjectGlyph(project: project, size: 42)
                Spacer(minLength: 16)
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let modified = project.modified {
                    Text(modified, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(width: 148, height: 164, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        }
        .buttonStyle(SquishStyle())
    }
}

private struct NewTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                Text("New Project")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.white.opacity(0.7))
            .frame(width: 148, height: 164)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
        }
        .buttonStyle(SquishStyle())
    }
}

/// A project's icon: its kind's symbol on a glowing, colored square.
private struct ProjectGlyph: View {
    let project: ProjectSummary
    let size: CGFloat

    var body: some View {
        Image(systemName: project.systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(project.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: project.color.opacity(0.5), radius: 10, y: 4)
    }
}

/// The floating bar with New, Open and Clone.
private struct ActionDock: View {
    let new: () -> Void
    let open: () -> Void
    let clone: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: new) {
                Label("New", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    .background(Color.ember.gradient, in: Capsule())
            }
            .accessibilityLabel("New Project")
            dockButton("Open", systemImage: "folder", action: open)
            dockButton("Clone", systemImage: "arrow.down.circle", action: clone)
        }
        .buttonStyle(SquishStyle())
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
    }

    private func dockButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
        }
    }
}

/// Every project, searchable, for when the shelf is not enough.
private struct AllProjectsView<Menu: View>: View {
    let summaries: [ProjectSummary]
    let open: (ProjectSummary) -> Void
    let menu: (ProjectSummary) -> Menu
    let reload: () -> Void
    @State private var search = ""

    var body: some View {
        List {
            ForEach(filtered) { project in
                Button {
                    open(project)
                } label: {
                    HStack(spacing: 14) {
                        ProjectGlyph(project: project, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .foregroundStyle(.primary)
                            HStack(spacing: 4) {
                                Text(project.kindLabel)
                                if let modified = project.modified {
                                    Text("·")
                                    Text(modified, format: .relative(presentation: .named))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu { menu(project) }
            }
        }
        .searchable(text: $search, prompt: "Search projects")
        .navigationTitle("All Projects")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { reload() }
    }

    private var filtered: [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return summaries }
        return summaries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

/// Shrinks slightly while pressed.
private struct SquishStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
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
