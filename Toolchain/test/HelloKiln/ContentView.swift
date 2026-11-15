import SwiftUI

struct ContentView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "flame.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Hello from Kiln")
                .font(.largeTitle.bold())
            Text("Tapped \(count) times")
                .foregroundStyle(.secondary)
            Button("Tap me") {
                count += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
