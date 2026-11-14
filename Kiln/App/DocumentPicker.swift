import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker directly with UIKit.
///
/// Embedding `UIDocumentPickerViewController` in a SwiftUI sheet breaks it: the picker
/// dismisses itself but leaves the sheet behind, and folder selection may not come through.
/// Presenting it modally avoids both, and (unlike `fileImporter`) it can start in a given folder.
@MainActor
enum DocumentPicker {
    /// Project folders, Swift packages (.swiftpm) and Xcode projects (.xcodeproj).
    static let projectTypes: [UTType] = {
        var types: [UTType] = [.folder, .package]
        for fileExtension in ["swiftpm", "xcodeproj", "xcworkspace"] {
            if let type = UTType(filenameExtension: fileExtension) { types.append(type) }
        }
        return types
    }()

    private static var activeDelegate: Delegate?

    static func present(contentTypes: [UTType], directoryURL: URL? = nil, onPick: @escaping (URL) -> Void) {
        guard let presenter = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.directoryURL = directoryURL
        picker.allowsMultipleSelection = false
        let delegate = Delegate { url in
            activeDelegate = nil
            if let url { onPick(url) }
        }
        activeDelegate = delegate
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void

        init(completion: @escaping (URL?) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(nil)
        }
    }
}
