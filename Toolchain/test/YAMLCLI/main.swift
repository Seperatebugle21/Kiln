import Foundation

// Checks Kiln's YAML reader (Kiln/Build/MiniYAML.swift) on an XcodeGen project like the ones users open.
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

let path = CommandLine.arguments[1]
let yaml = YAMLValue.parse(try String(contentsOfFile: path, encoding: .utf8))

expect(yaml["name"]?.string == "Demo", "name")
expect(yaml["settings"]?["base"]?["SWIFT_VERSION"]?.string == "5.9", "quoted value with trailing comment")
let packages = yaml["packages"]?.entries ?? []
expect(packages.map(\.key) == ["Models", "Soup", "Native"], "package names: \(packages.map(\.key))")
expect(yaml["packages"]?["Models"]?["exactVersion"]?.string == "2.25.6", "exactVersion")
expect(yaml["packages"]?["Native"]?["path"]?.string == "Packages/Native", "local path")

let targets = yaml["targets"]?.entries ?? []
expect(targets.map(\.key) == ["Demo", "DemoWidget"], "target names: \(targets.map(\.key))")
let app = yaml["targets"]?["Demo"]
expect(app?["type"]?.string == "application", "app type")
let sources = app?["sources"]?.items ?? []
expect(sources.count == 2, "app sources count \(sources.count)")
expect(sources.first?["path"]?.string == "Demo.swiftpm/Demo", "first source path")
expect(sources.last?["buildPhase"]?.string == "resources", "resource build phase")
expect(app?["settings"]?["base"]?["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]?.string == "$(inherited) DEMO_APP", "conditions")

let dependencies = app?["dependencies"]?.items ?? []
expect(dependencies.count == 4, "dependency count \(dependencies.count)")
expect(dependencies.first?["package"]?.string == "Models" && dependencies.first?["product"]?.string == "ModelsLLM", "package product")
expect(dependencies[safe: 1]?["package"]?.string == "Soup", "package without product")
expect(dependencies[safe: 2]?["framework"]?.string == "Python/Python.xcframework", "framework")
expect(dependencies[safe: 3]?["target"]?.string == "DemoWidget", "target dependency")
let script = app?["postBuildScripts"]?.items.first?["script"]?.string ?? ""
expect(script.contains("echo done"), "block scalar: \(script)")

let widget = yaml["targets"]?["DemoWidget"]
expect(widget?["sources"]?.items.compactMap(\.string) == ["DemoWidget", "Shared/Models.swift"], "flow list")
expect(widget?["settings"]?["PRODUCT_NAME"]?.string == "DemoWidget", "flow map")

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("YAML reader: all checks passed")
