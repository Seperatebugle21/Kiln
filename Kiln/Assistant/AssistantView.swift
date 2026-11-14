import SwiftUI

struct AssistantView: View {
    @Environment(AssistantSession.self) private var session
    @State private var draft = ""
    @State private var showsSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.hasAPIKey {
                    conversation
                } else {
                    ContentUnavailableView {
                        Label("Connect Claude", systemImage: "key")
                    } description: {
                        Text("Add your Anthropic API key to let Claude read, edit and build this project.")
                    } actions: {
                        Button("Open Settings") { showsSettings = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let change = session.pendingChange {
                    PendingChangeCard(change: change)
                }
                inputBar
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Conversation", systemImage: "square.and.pencil") { session.clear() }
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.items.isEmpty {
                        Text("Ask Claude to add a feature, explain code or fix a build error.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(session.items) { item in
                        ItemView(item: item)
                            .id(item.id)
                    }
                    if session.isWorking && session.pendingChange == nil {
                        ProgressView()
                            .padding(.vertical, 4)
                    }
                }
                .padding()
            }
            .onChange(of: session.items.count) {
                if let last = session.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .disabled(!session.hasAPIKey)
            if session.isWorking {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    session.send(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.hasAPIKey)
                .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .background(.bar)
    }
}

private struct ItemView: View {
    let item: AssistantSession.Item

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
            }
        case .assistant(let text):
            Text(markdown(text))
                .textSelection(.enabled)
        case .activity(let text):
            Label(text, systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct PendingChangeCard: View {
    @Environment(AssistantSession.self) private var session
    let change: AssistantSession.PendingChange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(change.isNewFile ? "Create \(change.path)" : "Edit \(change.path)", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(change.diff.prefix(400)) { line in
                        Text(prefix(line.kind) + line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                    }
                }
            }
            .frame(maxHeight: 240)
            HStack {
                Button("Reject", role: .destructive) { session.resolvePendingChange(approved: false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Apply") { session.resolvePendingChange(approved: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "- "
        case .unchanged: return "  "
        case .gap: return ""
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return .green.opacity(0.18)
        case .removed: return .red.opacity(0.18)
        default: return .clear
        }
    }
}
