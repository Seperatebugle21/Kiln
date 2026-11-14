import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(ProjectStore.self) private var projects
    @State private var isImporting = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "flame.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("Kiln")
                        .font(.largeTitle.bold())
                    Text("Write, build and run SwiftUI apps on your iPhone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 12) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Open Project Folder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        projects.createSampleProject()
                    } label: {
                        Label("New Sample Project", systemImage: "plus.square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .frame(maxWidth: 360)

                Text("Choose the folder that contains your .xcodeproj, a .swiftpm package or a folder of Swift files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    projects.open(url)
                case .failure(let error):
                    projects.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
