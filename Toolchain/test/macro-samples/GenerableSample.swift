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
