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
                // iOS loads only code signed by the same team as Kiln.
                return "Could not load the app: \(reason)\n\nIf this mentions the code signature: import the certificate Kiln itself is signed with under Settings › Build, then press Run again."
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

        // The app's strings, files and images, for code that looks them up in Bundle.main.
        MainBundleFallback.install()
        MainBundleFallback.bundle = product.resourceBundle.flatMap { Bundle(url: $0) }

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

/// Shows a running app full screen. There is no button on top of the app: a three-finger tap (or
/// coming back to Kiln from the background) opens Kiln's menu with Resume, Console, Restart and Stop.
struct RunnerView: View {
    let controller: UIViewController
    let appName: String
    let restart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var console = RunConsole.shared
    @State private var showsMenu = false
    @State private var showsConsole = false
    @State private var showsHint = true
    @State private var wasInBackground = false

    var body: some View {
        HostedController(controller: controller) {
            withAnimation(.spring(duration: 0.3)) { showsMenu = true }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if showsHint {
                Label("Tap with three fingers for the Kiln menu", systemImage: "hand.tap")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if showsMenu {
                RunnerMenu(
                    appName: appName,
                    consoleLines: console.lines.count,
                    resume: { withAnimation(.spring(duration: 0.3)) { showsMenu = false } },
                    console: { showsConsole = true },
                    restart: {
                        stop()
                        restart()
                    },
                    stop: stop
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showsConsole) {
            ConsoleView()
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            console.start()
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation { showsHint = false }
            }
        }
        .onDisappear {
            console.stop()
            MainBundleFallback.bundle = nil
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving Kiln and coming back opens the menu, so the app can be stopped or resumed.
            if phase == .background { wasInBackground = true }
            if phase == .active, wasInBackground {
                wasInBackground = false
                withAnimation(.spring(duration: 0.3)) { showsMenu = true }
            }
        }
    }

    private func stop() {
        console.stop()
        dismiss()
    }
}

/// Kiln's menu over a running app.
private struct RunnerMenu: View {
    let appName: String
    let consoleLines: Int
    let resume: () -> Void
    let console: () -> Void
    let restart: () -> Void
    let stop: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture(perform: resume)
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(appName)
                        .font(.title3.bold())
                    Text("Running in Kiln")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    Button(action: resume) {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack(spacing: 10) {
                        Button(action: console) {
                            VStack(spacing: 4) {
                                Image(systemName: "terminal")
                                    .font(.title3)
                                Text(consoleLines > 0 ? "Console (\(consoleLines))" : "Console")
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        Button(action: restart) {
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.title3)
                                Text("Restart")
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive, action: stop) {
                        Label("Stop App", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                Text("Tap with three fingers to open this menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            .padding(24)
        }
    }
}

/// What the running app printed.
struct ConsoleView: View {
    @State private var console = RunConsole.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if console.lines.isEmpty {
                            Text("Nothing printed yet. Output of print() appears here.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(console.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: console.lines.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", systemImage: "trash") { console.clear() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = console.text }
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Hosts the app's view controller and listens for a three-finger tap on top of it.
private struct HostedController: UIViewControllerRepresentable {
    let controller: UIViewController
    let onThreeFingerTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onThreeFingerTap: onThreeFingerTap) }

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.numberOfTouchesRequired = 3
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        container.view.addGestureRecognizer(tap)
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.onThreeFingerTap = onThreeFingerTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onThreeFingerTap: () -> Void

        init(onThreeFingerTap: @escaping () -> Void) {
            self.onThreeFingerTap = onThreeFingerTap
        }

        @objc func tapped() {
            onThreeFingerTap()
        }

        /// The app's own gestures keep working alongside Kiln's.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
