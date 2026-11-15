import Darwin
import SwiftUI
import UIKit

/// Loads a built dylib into Kiln and returns the app's root view controller.
enum AppRunner {
    enum Failure: LocalizedError {
        case load(String)
        case missingEntry

        var errorDescription: String? {
            switch self {
            case .load(let reason):
                // Until Kiln signs with the developer certificate, built apps are ad-hoc signed,
                // which iOS only accepts while a debugger (JIT) is attached.
                return "Could not load the app: \(reason)\n\nKiln signs built apps ad hoc for now. Enable JIT for Kiln (for example with StikDebug) and press Run again."
            case .missingEntry: return "The built app does not export \(EntryPointGenerator.entrySymbol)."
            }
        }
    }

    private typealias Entry = @convention(c) () -> UnsafeMutableRawPointer

    @MainActor
    static func load(_ product: BuildProduct) throws -> UIViewController {
        // dyld caches images by path, so every run gets a fresh copy.
        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("KilnRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let copy = runs.appendingPathComponent(UUID().uuidString + ".dylib")
        try FileManager.default.copyItem(at: product.dylib, to: copy)

        guard let handle = dlopen(copy.path, RTLD_NOW | RTLD_LOCAL) else {
            throw Failure.load(dlerror().map { String(cString: $0) } ?? "unknown error")
        }
        guard let symbol = dlsym(handle, EntryPointGenerator.entrySymbol) else {
            throw Failure.missingEntry
        }
        let entry = unsafeBitCast(symbol, to: Entry.self)
        return Unmanaged<UIViewController>.fromOpaque(entry()).takeRetainedValue()
    }
}

/// Shows a running app full screen with a button to return to Kiln.
struct RunnerView: View {
    let controller: UIViewController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HostedController(controller: controller)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                }
                .padding()
                .accessibilityLabel("Stop app")
            }
    }
}

private struct HostedController: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
