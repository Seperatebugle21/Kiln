import SwiftUI

struct FileTreeView: View {
    @Environment(ProjectStore.self) private var projects
    @State private var newFileFolder: URL?
    @State private var isNamingNewFile = false
    @State private var newFileName = ""
    @State private var pendingDeletion: FileNode?

    var body: some View {
        List {
            Section {
                OutlineGroup(projects.tree, children: \.children) { node in
                    row(for: node)
                }
            } header: {
                Text(projects.kind.rawValue)
            }
        }
        .listStyle(.sidebar)
        .refreshable { projects.reloadTree() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    askForNewFile(in: nil)
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
            }
        }
        .alert("New File", isPresented: $isNamingNewFile) {
            TextField("Name.swift", text: $newFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                let name = newFileName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { projects.createFile(named: name, in: newFileFolder) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let node = pendingDeletion { projects.delete(node.url) }
                pendingDeletion = nil
            }
        }
    }

    @ViewBuilder
    private func row(for node: FileNode) -> some View {
        let isSelected = node.url == projects.selectedFile
        Button {
            if !node.isDirectory { projects.select(node.url) }
        } label: {
            Label(node.name, systemImage: node.systemImage)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if ProjectStore.isOpenableProject(node.url) || node.url.pathExtension.lowercased() == "zip" {
                Button("Open as Project", systemImage: "arrow.up.forward.app") { projects.open(node.url) }
            }
            if node.isDirectory {
                Button("New File Here", systemImage: "doc.badge.plus") { askForNewFile(in: node.url) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = node }
        }
    }

    private func askForNewFile(in folder: URL?) {
        newFileFolder = folder
        newFileName = ""
        isNamingNewFile = true
    }
}
