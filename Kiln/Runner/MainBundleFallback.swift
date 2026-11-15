import Foundation
import ObjectiveC
import UIKit

/// While an app runs inside Kiln, Bundle.main is Kiln's own bundle, so the app's localized strings,
/// files and images (looked up in Bundle.main by Xcode apps) were not found. This makes Bundle.main
/// fall back to the app's resource bundle for anything Kiln itself does not have:
/// localized strings (String(localized:), Text("…"), NSLocalizedString), url/path(forResource:)
/// and UIImage(named:).
enum MainBundleFallback {
    /// The running app's resources; nil when no app runs.
    nonisolated(unsafe) static var bundle: Bundle?
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        swap(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:)), #selector(Bundle.kiln_localizedString(forKey:value:table:)))
        swap(Bundle.self, #selector(Bundle.url(forResource:withExtension:subdirectory:)), #selector(Bundle.kiln_url(forResource:withExtension:subdirectory:)))
        swap(Bundle.self, #selector(Bundle.url(forResource:withExtension:)), #selector(Bundle.kiln_url(forResource:withExtension:)))
        swap(Bundle.self, #selector(Bundle.path(forResource:ofType:)), #selector(Bundle.kiln_path(forResource:ofType:)))
        swap(Bundle.self, #selector(Bundle.path(forResource:ofType:inDirectory:)), #selector(Bundle.kiln_path(forResource:ofType:inDirectory:)))
        if let original = class_getClassMethod(UIImage.self, NSSelectorFromString("imageNamed:")),
           let replacement = class_getClassMethod(UIImage.self, NSSelectorFromString("kiln_imageNamed:")) {
            method_exchangeImplementations(original, replacement)
        }
    }

    private static func swap(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(type, original),
              let replacementMethod = class_getInstanceMethod(type, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// The fallback bundle, when `bundle` is Kiln's main bundle and an app is running.
    static func fallback(for bundle: Bundle) -> Bundle? {
        guard let fallback = Self.bundle, bundle === Bundle.main else { return nil }
        return fallback
    }
}

extension Bundle {
    // After the exchange, calling kiln_… runs the original implementation.

    @objc func kiln_localizedString(forKey key: String, value: String?, table: String?) -> String {
        let result = kiln_localizedString(forKey: key, value: value, table: table)
        guard let fallback = MainBundleFallback.fallback(for: self) else { return result }
        let notFound = result == key || (value.map { !$0.isEmpty && result == $0 } ?? false)
        return notFound ? fallback.localizedString(forKey: key, value: value, table: table) : result
    }

    @objc func kiln_url(forResource name: String?, withExtension ext: String?, subdirectory: String?) -> URL? {
        kiln_url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            ?? MainBundleFallback.fallback(for: self)?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    @objc func kiln_url(forResource name: String?, withExtension ext: String?) -> URL? {
        kiln_url(forResource: name, withExtension: ext)
            ?? MainBundleFallback.fallback(for: self)?.url(forResource: name, withExtension: ext)
    }

    @objc func kiln_path(forResource name: String?, ofType ext: String?) -> String? {
        kiln_path(forResource: name, ofType: ext)
            ?? MainBundleFallback.fallback(for: self)?.path(forResource: name, ofType: ext)
    }

    @objc func kiln_path(forResource name: String?, ofType ext: String?, inDirectory subpath: String?) -> String? {
        kiln_path(forResource: name, ofType: ext, inDirectory: subpath)
            ?? MainBundleFallback.fallback(for: self)?.path(forResource: name, ofType: ext, inDirectory: subpath)
    }
}

extension UIImage {
    @objc(kiln_imageNamed:) class func kiln_image(named name: String) -> UIImage? {
        if let image = kiln_image(named: name) { return image }
        guard let fallback = MainBundleFallback.bundle else { return nil }
        return UIImage(named: name, in: fallback, compatibleWith: nil)
    }
}
