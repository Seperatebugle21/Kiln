import SwiftUI

struct SettingsView: View {
    @Environment(AssistantSession.self) private var session
    @Environment(SyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AssistantSession.modelKey) private var model = ClaudeClient.defaultModel
    @AppStorage(AssistantSession.effortKey) private var effort = "high"
    @AppStorage(AssistantSession.autoApplyKey) private var autoApply = false
    @State private var apiKey = ""
    @State private var githubToken = ""

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
                    LabeledContent("Compiler", value: LocalToolchainBackend.isInstalled ? "Installed" : "Not bundled yet")
                    LabeledContent("Signing", value: "Coming with the compiler")
                } header: {
                    Text("Build")
                } footer: {
                    Text("Kiln compiles on this device with a bundled Swift toolchain and signs the result with your development certificate.")
                }
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
}
