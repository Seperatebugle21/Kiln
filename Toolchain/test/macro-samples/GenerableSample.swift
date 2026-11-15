import FoundationModels

@Generable(description: "A song to play")
struct SongPick {
    @Guide(description: "The song title")
    var title: String
    @Guide(description: "How many", .range(1...5))
    var count: Int
    var tags: [String]
    var rating: Double?
}

@Generable
enum Mood {
    case happy, sad
}

@Generable
enum Action {
    case play(song: String)
    case stop
}

@Generable
enum Choice {
    case pick(String, Int)
    case none
}

@Generable
public struct PublicThing {
    @Guide(description: "Name")
    public var name: String
    public var computed: Int { 1 }
    public let fixed: Int = 3
}

// Uses the generated members the way apps do.
func use(_ pick: SongPick, _ content: GeneratedContent) throws {
    _ = SongPick.generationSchema
    _ = pick.generatedContent
    _ = try SongPick(content)
    _ = try SongPick.PartiallyGenerated(content)
    _ = try Action(content)
    _ = try Choice(content)
    _ = try Mood(content)
}
