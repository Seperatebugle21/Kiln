import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AssistantSession.self) private var session
    @Environment(SyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AssistantSession.modelKey) private var model = ClaudeClient.defaultModel
    @AppStorage(AssistantSession.effortKey) private var effort = "high"
    @AppStorage(AssistantSession.autoApplyKey) private var autoApply = false
    @State private var apiKey = ""
    @State private var githubToken = ""
    @State private var signingSummary: String?
    @State private var pendingCertificate: Data?
    @State private var certificatePassword = ""
    @State private var signingError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(session.hasAPIKey ? "Saved — enter a new key to replace it" : "sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if session.hasAPIKey {
                        Button("Remove API Key", role: .destructive) {
                            session.setAPIKey("")
                        }
                    }
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    Text("Stored in the Keychain on this device and only sent to api.anthropic.com.")
                }

                Section("Claude") {
                    Picker("Model", selection: $model) {
                        ForEach(ClaudeClient.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Picker("Effort", selection: $effort) {
                        ForEach(ClaudeClient.efforts, id: \.self) { effort in
                            Text(effort.capitalized).tag(effort)
                        }
                    }
                    Toggle("Apply Changes Without Asking", isOn: $autoApply)
                }

                Section {
                    SecureField(sync.hasToken ? "Saved — enter a new token to replace it" : "github_pat_…", text: $githubToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if sync.hasToken {
                        Button("Remove GitHub Token", role: .destructive) {
                            sync.setToken("")
                        }
                    }
                } header: {
                    Text("GitHub")
                } footer: {
                    Text("Create a fine-grained token on github.com under Settings › Developer settings › Personal access tokens, with access to your project repositories and the permission Contents: Read and write. Stored in the Keychain.")
                }

                Section {
                    LabeledContent("Compiler", value: LocalToolchainBackend.isInstalled ? "Installed" : "Not included")
                    if let signingSummary {
                        LabeledContent("Certificate", value: signingSummary)
                        Button("Remove Certificate", role: .destructive) {
                            SigningIdentityStore.remove()
                            self.signingSummary = nil
                        }
                    } else {
                        Button("Import Signing Certificate (.p12)…") {
                            DocumentPicker.present(contentTypes: [.pkcs12]) { url in
                                let accessing = url.startAccessingSecurityScopedResource()
                                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                                if let data = try? Data(contentsOf: url) {
                                    certificatePassword = ""
                                    pendingCertificate = data
                                } else {
                                    signingError = "Could not read \(url.lastPathComponent)."
                                }
                            }
                        }
                    }
                } header: {
                    Text("Build")
                } footer: {
                    Text("Kiln signs the apps it builds with this certificate, so iOS loads them without JIT. Use the same certificate (developer or enterprise) that Kiln itself is signed with; the Team IDs must match. Stored in the Keychain.")
                }
                Section {
                    NavigationLink {
                        BuildLogsView()
                    } label: {
                        Label("Build Logs", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Logs of recent builds, also of builds that crashed Kiln.")
                }
            }
            .onAppear(perform: loadSigningSummary)
            .alert(
                "Certificate Password",
                isPresented: Binding(get: { pendingCertificate != nil }, set: { if !$0 { pendingCertificate = nil } })
            ) {
                SecureField("Password", text: $certificatePassword)
                Button("Import") { importCertificate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the password of the .p12 file.")
            }
            .alert(
                "Signing Certificate",
                isPresented: Binding(get: { signingError != nil }, set: { if !$0 { signingError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(signingError ?? "")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !apiKey.isEmpty { session.setAPIKey(apiKey) }
                        if !githubToken.isEmpty { sync.setToken(githubToken) }
                        dismiss()
                    }
                }
            }
        }
    }

    private func loadSigningSummary() {
        guard SigningIdentityStore.isConfigured else { signingSummary = nil; return }
        if let identity = try? SigningIdentityStore.load(appleCertificates: SigningIdentityStore.bundledAppleCertificates()) {
            signingSummary = "\(identity.name) (\(identity.teamID))"
        } else {
            signingSummary = "Saved, but it could not be read"
        }
    }

    private func importCertificate() {
        guard let data = pendingCertificate else { return }
        pendingCertificate = nil
        do {
            let identity = try SigningIdentityStore.save(
                p12: data,
                password: certificatePassword,
                appleCertificates: SigningIdentityStore.bundledAppleCertificates()
            )
            signingSummary = "\(identity.name) (\(identity.teamID))"
        } catch {
            signingError = error.localizedDescription
        }
        certificatePassword = ""
    }
}
