import Foundation
import Observation

/// The conversation with Claude and the tool loop that lets it read, edit and build the project.
@MainActor
@Observable
final class AssistantSession {
    struct Item: Identifiable {
        enum Kind {
            case user(String)
            case assistant(String)
            case activity(String)
            case error(String)
        }

        let id = UUID()
        let kind: Kind
    }

    struct PendingChange: Identifiable {
        let id = UUID()
        let path: String
        let isNewFile: Bool
        let diff: [DiffLine]
    }

    static let modelKey = "kiln.assistant.model"
    static let effortKey = "kiln.assistant.effort"
    static let autoApplyKey = "kiln.assistant.autoApply"
    static let apiKeyAccount = "anthropic-api-key"

    private(set) var items: [Item] = []
    private(set) var isWorking = false
    private(set) var pendingChange: PendingChange?

    private let projects: ProjectStore
    private let builds: BuildCoordinator
    private var messages: [JSONValue] = []
    private var currentTask: Task<Void, Never>?
    /// Number of API messages before the current request, to roll back a turn that failed.
    private var turnStart = 0
    private var approval: CheckedContinuation<Bool, Never>?
    private let maxToolRounds = 40

    init(projects: ProjectStore, builds: BuildCoordinator) {
        self.projects = projects
        self.builds = builds
    }

    private(set) var hasAPIKey = !(Keychain.read(AssistantSession.apiKeyAccount) ?? "").isEmpty

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(trimmed.isEmpty ? nil : trimmed, for: Self.apiKeyAccount)
        hasAPIKey = !trimmed.isEmpty
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        items.append(Item(kind: .user(trimmed)))
        var prompt = trimmed
        if let file = projects.selectedFile {
            prompt += "\n\n(The file open in the editor is \(projects.relativePath(of: file)).)"
        }
        turnStart = messages.count
        messages.append(["role": "user", "content": .string(prompt)])
        currentTask = Task { await runLoop() }
    }

    func stop() {
        currentTask?.cancel()
        resolvePendingChange(approved: false)
    }

    func clear() {
        stop()
        items = []
        messages = []
    }

    func resolvePendingChange(approved: Bool) {
        pendingChange = nil
        approval?.resume(returning: approved)
        approval = nil
    }

    // MARK: Agent loop

    private func runLoop() async {
        isWorking = true
        defer { isWorking = false }

        let defaults = UserDefaults.standard
        let client = ClaudeClient(
            apiKey: Keychain.read(Self.apiKeyAccount) ?? "",
            model: defaults.string(forKey: Self.modelKey) ?? ClaudeClient.defaultModel,
            effort: defaults.string(forKey: Self.effortKey) ?? "high"
        )

        for _ in 0..<maxToolRounds {
            if Task.isCancelled { return finishCancelled() }

            let response: JSONValue
            do {
                response = try await client.send(
                    system: AssistantTools.systemPrompt,
                    messages: messages,
                    tools: AssistantTools.definitions
                )
            } catch {
                if Task.isCancelled { return finishCancelled() }
                rollBackTurn()
                items.append(Item(kind: .error(error.localizedDescription + " (This message was not kept; send it again.)")))
                return
            }

            let content = response["content"]?.arrayValue ?? []
            // Content goes back exactly as received, thinking blocks included.
            messages.append(["role": "assistant", "content": .array(content)])

            for block in content where block["type"]?.stringValue == "text" {
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    items.append(Item(kind: .assistant(text)))
                }
            }

            let stopReason = response["stop_reason"]?.stringValue
            if stopReason == "refusal" {
                items.append(Item(kind: .error("Claude declined this request.")))
                return
            }
            if stopReason == "max_tokens" {
                items.append(Item(kind: .error("The reply hit the length limit. Ask Claude to continue.")))
                return
            }

            let toolUses = content.filter { $0["type"]?.stringValue == "tool_use" }
            guard stopReason == "tool_use", !toolUses.isEmpty else { return }

            var results: [JSONValue] = []
            for toolUse in toolUses {
                let id = toolUse["id"]?.stringValue ?? ""
                let name = toolUse["name"]?.stringValue ?? ""
                let input = toolUse["input"] ?? [:]
                let (output, isError) = await run(tool: name, input: input)
                results.append([
                    "type": "tool_result",
                    "tool_use_id": .string(id),
                    "content": .string(output),
                    "is_error": .bool(isError),
                ])
            }
            // All results for one assistant turn go back in a single user message.
            messages.append(["role": "user", "content": .array(results)])
        }
        items.append(Item(kind: .error("Stopped after \(maxToolRounds) tool rounds.")))
    }

    private func finishCancelled() {
        items.append(Item(kind: .activity("Stopped. Changes already saved stay in the project.")))
        rollBackTurn()
    }

    /// Removes the unfinished turn so the next request starts from a valid conversation.
    private func rollBackTurn() {
        if messages.count > turnStart {
            messages.removeSubrange(turnStart...)
        }
    }

    // MARK: Tools

    private func run(tool name: String, input: JSONValue) async -> (String, Bool) {
        do {
            switch name {
            case "list_files":
                items.append(Item(kind: .activity("Listed project files")))
                let files = projects.allFilePaths()
                return (files.isEmpty ? "(The project has no files.)" : files.joined(separator: "\n"), false)

            case "read_file":
                let path = try string(input, "path")
                items.append(Item(kind: .activity("Read \(path)")))
                return (try projects.readFile(path), false)

            case "edit_file":
                let path = try string(input, "path")
                let oldString = try string(input, "old_string")
                let newString = try string(input, "new_string")
                let current = try projects.readFile(path)
                let occurrences = current.components(separatedBy: oldString).count - 1
                guard !oldString.isEmpty, occurrences == 1 else {
                    return ("old_string occurs \(occurrences) times in \(path); it must occur exactly once. Read the file again and include more context.", true)
                }
                let updated = current.replacingOccurrences(of: oldString, with: newString)
                return try await apply(updated, to: path, previous: current)

            case "write_file":
                let path = try string(input, "path")
                let content = try string(input, "content")
                var previous: String?
                if projects.fileExists(path) {
                    previous = try projects.readFile(path)
                }
                return try await apply(content, to: path, previous: previous)

            case "build_project":
                items.append(Item(kind: .activity("Building…")))
                let succeeded = await builds.build(projects)
                items.append(Item(kind: .activity(succeeded ? "Build succeeded" : "Build failed")))
                return (builds.report(), false)

            default:
                return ("Unknown tool \(name).", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func apply(_ contents: String, to path: String, previous: String?) async throws -> (String, Bool) {
        let change = PendingChange(
            path: path,
            isNewFile: previous == nil,
            diff: LineDiff.diff(old: previous ?? "", new: contents)
        )
        guard await requestApproval(change) else {
            items.append(Item(kind: .activity("Rejected change to \(path)")))
            return ("The user rejected this change to \(path). Ask them what they want instead.", true)
        }
        try projects.writeFile(path, contents: contents)
        items.append(Item(kind: .activity("\(previous == nil ? "Created" : "Edited") \(path)")))
        return ("Saved \(path).", false)
    }

    private func requestApproval(_ change: PendingChange) async -> Bool {
        if UserDefaults.standard.bool(forKey: Self.autoApplyKey) { return true }
        if Task.isCancelled { return false }
        return await withCheckedContinuation { continuation in
            approval = continuation
            pendingChange = change
        }
    }

    private func string(_ input: JSONValue, _ key: String) throws -> String {
        guard let value = input[key]?.stringValue else {
            throw ToolInputError(field: key)
        }
        return value
    }
}

private struct ToolInputError: LocalizedError {
    let field: String
    var errorDescription: String? { "Missing or invalid input field \"\(field)\"." }
}
