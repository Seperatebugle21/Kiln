import Foundation

/// Compiles on the device with the bundled Swift toolchain (phase 2).
///
/// The toolchain (swift-frontend, lld and the iPhoneOS SDK interfaces) is built for iOS by
/// the `Toolchain` workflow and bundled as `Toolchain/` in the app. Until that lands, this
/// backend reports that it is unavailable instead of pretending to build.
struct LocalToolchainBackend: BuildBackend {
    let name = "On-device compiler"

    static var toolchainURL: URL? {
        Bundle.main.url(forResource: "Toolchain", withExtension: nil)
    }

    static var isInstalled: Bool { toolchainURL != nil }

    func build(_ request: BuildRequest, log: @escaping @Sendable (String) -> Void) async throws -> BuildProduct {
        guard Self.toolchainURL != nil else {
            throw BuildError.backendUnavailable(
                "The on-device Swift compiler is not bundled in this build of Kiln yet. "
                + "Syntax checking and the entry point worked; compiling arrives with the toolchain (phase 2)."
            )
        }
        log("Toolchain found, but the compiler driver is not wired up yet.")
        throw BuildError.backendUnavailable("The on-device compiler driver is not implemented yet.")
    }
}
