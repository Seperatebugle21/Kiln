import Foundation

// Stand-ins for what the app provides: the compilers as processes instead of linked libraries,
// and no signing (CI only checks that projects build).

private func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (127, "cannot run \(executable): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func strings(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafePointer<CChar>>) -> [String] {
    (0..<Int(argc)).map { String(cString: argv[$0]) }
}

/// The compilers write diagnostics to stderr, which the backend captures from this process.
private func forward(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func kiln_toolchain_available() -> Int32 { 1 }

func kiln_swift_frontend(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafePointer<CChar>>) -> Int32 {
    let arguments = strings(argc, argv)
    let frontend = ProcessInfo.processInfo.environment["KILN_SWIFT_FRONTEND"] ?? "/usr/bin/false"
    let (status, output) = run(frontend, Array(arguments.dropFirst()))
    forward(output)
    return status
}

func kiln_clang(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafePointer<CChar>>) -> Int32 {
    let arguments = strings(argc, argv)
    let (status, output) = run("/usr/bin/xcrun", ["clang"] + Array(arguments.dropFirst()))
    forward(output)
    return status
}

func kiln_lld_link(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafePointer<CChar>>, _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let arguments = strings(argc, argv)
    let lld = ProcessInfo.processInfo.environment["KILN_LLD"] ?? "/usr/bin/false"
    let (status, text) = run(lld, Array(arguments.dropFirst()))
    output.pointee = strdup(text)
    return status
}

struct SigningIdentity {
    var name = ""
    var teamID = ""
    var privateKey = 0
    var certificates: [Data] = []
}

enum SigningIdentityStore {
    static func bundledAppleCertificates() -> [Data] { [] }
    static func load(appleCertificates: [Data]) throws -> SigningIdentity? { nil }
}

struct MachOSigner {
    var privateKey: Int
    var certificates: [Data]
    var teamID: String
    func sign(fileAt url: URL, identifier: String) throws {}
}
