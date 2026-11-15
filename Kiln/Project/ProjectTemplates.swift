import Foundation

/// Starting points for a new project. Each template produces files relative to the project folder,
/// with the app's sources in `<Name>/`.
enum ProjectTemplate: String, CaseIterable, Identifiable {
    case empty
    case helloWorld
    case notes
    case game
    case packages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .empty: return "Empty App"
        case .helloWorld: return "Hello World"
        case .notes: return "Notes List"
        case .game: return "Tap Game"
        case .packages: return "Packages & C"
        }
    }

    var summary: String {
        switch self {
        case .empty: return "An App struct and an empty ContentView."
        case .helloWorld: return "A small screen with a counter, using @Observable."
        case .notes: return "A list with navigation, add and delete, and a detail screen."
        case .game: return "A little game: tap the moving dots before time runs out."
        case .packages: return "A local Swift package with a C target, @Observable and #Preview."
        }
    }

    var systemImage: String {
        switch self {
        case .empty: return "doc"
        case .helloWorld: return "hand.wave"
        case .notes: return "list.bullet"
        case .game: return "gamecontroller"
        case .packages: return "shippingbox"
        }
    }

    /// A Swift type name from what the user typed: "my cool app" → "MyCoolApp".
    static func typeName(for projectName: String) -> String {
        let words = projectName.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        var name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        if name.isEmpty { name = "MyApp" }
        if name.first?.isNumber == true { name = "App" + name }
        return name
    }

    func files(projectName: String) -> [String: String] {
        let type = Self.typeName(for: projectName)
        let folder = type
        var files = [
            "\(folder)/\(type)App.swift": Self.appSource(type: type),
            "\(folder)/ContentView.swift": contentView(title: projectName),
        ]
        switch self {
        case .notes:
            files["\(folder)/NoteStore.swift"] = Self.noteStore
        case .game:
            files["\(folder)/Game.swift"] = Self.gameModel
        case .packages:
            files.merge(SampleProject.packageFiles) { _, new in new }
        default:
            break
        }
        return files
    }

    private static func appSource(type: String) -> String {
        """
        import SwiftUI

        @main
        struct \(type)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        """
    }

    private func contentView(title: String) -> String {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch self {
        case .empty:
            return """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("\(escaped)")
                }
            }

            """
        case .helloWorld:
            return """
            import Observation
            import SwiftUI

            @Observable
            final class Counter {
                var count = 0
            }

            struct ContentView: View {
                @State private var counter = Counter()

                var body: some View {
                    VStack(spacing: 24) {
                        Image(systemName: "globe")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Hello, world!")
                            .font(.largeTitle.bold())
                        Text("Tapped \\(counter.count) times")
                            .foregroundStyle(.secondary)
                        Button("Tap me") {
                            counter.count += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }

            """
        case .notes:
            return """
            import SwiftUI

            struct ContentView: View {
                @State private var store = NoteStore()

                var body: some View {
                    NavigationStack {
                        List {
                            ForEach($store.notes) { $note in
                                NavigationLink {
                                    NoteDetail(note: $note)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(note.title.isEmpty ? "Untitled" : note.title)
                                            .font(.headline)
                                        Text(note.created, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .onDelete { store.notes.remove(atOffsets: $0) }
                        }
                        .navigationTitle("\(escaped)")
                        .toolbar {
                            Button("Add", systemImage: "plus") {
                                store.add()
                            }
                        }
                        .overlay {
                            if store.notes.isEmpty {
                                ContentUnavailableView("No Notes", systemImage: "note.text", description: Text("Tap + to add one."))
                            }
                        }
                    }
                }
            }

            struct NoteDetail: View {
                @Binding var note: Note

                var body: some View {
                    Form {
                        TextField("Title", text: $note.title)
                        TextField("Text", text: $note.body, axis: .vertical)
                            .lineLimit(5...)
                    }
                    .navigationTitle(note.title.isEmpty ? "Untitled" : note.title)
                }
            }

            """
        case .game:
            return """
            import SwiftUI

            struct ContentView: View {
                @State private var game = Game()

                var body: some View {
                    VStack(spacing: 12) {
                        HStack {
                            Label("\\(game.score)", systemImage: "star.fill")
                            Spacer()
                            Label("\\(game.timeLeft)s", systemImage: "timer")
                        }
                        .font(.title2.bold())
                        .padding(.horizontal)

                        GeometryReader { proxy in
                            ZStack {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(.quaternary)
                                ForEach(game.dots) { dot in
                                    Circle()
                                        .fill(dot.color.gradient)
                                        .frame(width: dot.size, height: dot.size)
                                        .position(x: dot.x * proxy.size.width, y: dot.y * proxy.size.height)
                                        .onTapGesture { game.tap(dot) }
                                        .transition(.scale.combined(with: .opacity))
                                }
                                if !game.isRunning {
                                    VStack(spacing: 16) {
                                        Text(game.score == 0 ? "Tap the dots!" : "Score: \\(game.score)")
                                            .font(.largeTitle.bold())
                                        Button(game.score == 0 ? "Start" : "Play Again") {
                                            game.start()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .animation(.spring(duration: 0.3), value: game.dots)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                            game.tick()
                        }
                    }
                }
            }

            """
        case .packages:
            return SampleProject.contentViewSource
        }
    }

    private static let noteStore = """
    import Foundation
    import Observation

    struct Note: Identifiable, Hashable {
        let id = UUID()
        var title: String
        var body = ""
        var created = Date()
    }

    @Observable
    final class NoteStore {
        var notes: [Note] = [
            Note(title: "Welcome to Kiln"),
            Note(title: "Swipe left to delete"),
        ]

        func add() {
            notes.insert(Note(title: "New Note"), at: 0)
        }
    }

    """

    private static let gameModel = """
    import Observation
    import SwiftUI

    struct Dot: Identifiable, Equatable {
        let id = UUID()
        var x: Double
        var y: Double
        var size: Double
        var color: Color
        var expires: Date
    }

    @Observable
    final class Game {
        var dots: [Dot] = []
        var score = 0
        var timeLeft = 30
        var isRunning = false
        private var endDate = Date()
        private var nextDot = Date()

        func start() {
            score = 0
            dots = []
            endDate = .now.addingTimeInterval(30)
            nextDot = .now
            isRunning = true
        }

        func tap(_ dot: Dot) {
            guard isRunning, let index = dots.firstIndex(of: dot) else { return }
            dots.remove(at: index)
            // Smaller dots are worth more.
            score += dot.size < 50 ? 3 : 1
        }

        func tick() {
            guard isRunning else { return }
            let now = Date.now
            timeLeft = max(0, Int(endDate.timeIntervalSince(now).rounded(.up)))
            if timeLeft == 0 {
                isRunning = false
                dots = []
                return
            }
            dots.removeAll { $0.expires < now }
            if now >= nextDot {
                let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
                dots.append(Dot(
                    x: .random(in: 0.12...0.88),
                    y: .random(in: 0.12...0.88),
                    size: .random(in: 36...80),
                    color: colors.randomElement()!,
                    expires: now.addingTimeInterval(.random(in: 1.2...2.2))
                ))
                // The game speeds up as time runs out.
                nextDot = now.addingTimeInterval(0.3 + Double(timeLeft) / 60)
            }
        }
    }

    """
}
