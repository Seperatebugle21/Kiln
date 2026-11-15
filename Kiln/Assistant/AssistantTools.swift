import Foundation

/// The tools Claude can use inside Kiln. All paths are relative to the project folder.
enum AssistantTools {
    static let definitions: [JSONValue] = [
        tool(
            "list_files",
            "List every file in the open project, one project-relative path per line.",
            properties: [:],
            required: []
        ),
        tool(
            "read_file",
            "Read a UTF-8 text file from the project. Includes unsaved editor changes.",
            properties: ["path": ["type": "string", "description": "Project-relative path, e.g. MyApp/ContentView.swift"]],
            required: ["path"]
        ),
        tool(
            "edit_file",
            "Replace one exact occurrence of old_string with new_string in a file. old_string must match the file "
                + "exactly, including indentation, and occur exactly once; include surrounding lines to make it unique. "
                + "The user reviews the change before it is applied.",
            properties: [
                "path": ["type": "string", "description": "Project-relative path"],
                "old_string": ["type": "string", "description": "Exact text to replace"],
                "new_string": ["type": "string", "description": "Replacement text"],
            ],
            required: ["path", "old_string", "new_string"]
        ),
        tool(
            "write_file",
            "Create a file or replace its whole contents. Prefer edit_file for changes to an existing file. "
                + "The user reviews the change before it is applied.",
            properties: [
                "path": ["type": "string", "description": "Project-relative path"],
                "content": ["type": "string", "description": "The complete new file contents"],
            ],
            required: ["path", "content"]
        ),
        tool(
            "build_project",
            "Build the project the way the Run button does and return the build log with any errors and warnings.",
            properties: [:],
            required: []
        ),
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ],
        ]
    }

    static let systemPrompt = """
    You are Claude, the coding assistant built into Kiln, an IDE that runs on the user's iPhone or iPad. \
    You work on the user's open project with the tools provided: list and read files, edit or write files, and build.

    About the projects:
    - They are SwiftUI apps for iOS 26. Write modern Swift and SwiftUI (Observation, NavigationStack, async/await).
    - Kiln runs an app by removing @main from the App struct and showing the content of its WindowGroup in a \
    hosting controller, so the app needs a `@main struct …: App` with a `WindowGroup { … }`. App delegate adaptors are not supported.
    - Kiln builds the app's Swift files, Swift package dependencies (local, or from GitHub), C/C++/Objective-C \
    package targets and app sources exposed through a bridging header. Not yet supported: binary (.xcframework) \
    targets, package resources, asset catalogs, and Apple's closed-source macros other than #Preview \
    (for example SwiftData's @Model); @Observable works.

    How to work:
    - Read a file before you edit it, and keep edits small and focused with edit_file.
    - After changing code, call build_project and fix any errors it reports before you finish.
    - The user approves every file change; if they reject one, ask what they would like instead.
    - Reply in the user's language. Keep explanations short; the user is on a phone.
    """
}
