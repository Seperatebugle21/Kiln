import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system document picker, which (unlike `fileImporter`) can start in a given folder.
struct DocumentPicker: UIViewControllerRepresentable {
    var contentTypes: [UTType]
    var directoryURL: URL?
    var onPick: (URL) -> Void

    /// Project folders, Swift packages (.swiftpm) and Xcode projects (.xcodeproj).
    static let projectTypes: [UTType] = {
        var types: [UTType] = [.folder, .package]
        for fileExtension in ["swiftpm", "xcodeproj", "xcworkspace"] {
            if let type = UTType(filenameExtension: fileExtension) { types.append(type) }
        }
        return types
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.directoryURL = directoryURL
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
