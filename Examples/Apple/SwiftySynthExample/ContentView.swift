import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SynthEngine()

    var body: some View {
        VStack(spacing: 16) {
            Text("SwiftySynth Example").font(.title2).bold()
            Button(engine.isPlaying ? "Stop" : "Play") {
                engine.isPlaying ? engine.stop() : engine.play()
            }
            .buttonStyle(.borderedProminent)
            VStack(alignment: .leading, spacing: 4) {
                Text("SoundFont: \(engine.soundFontName ?? "— (drop one into Sounds/)")")
                Text("MIDI: \(engine.midiName ?? "—")")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let msg = engine.errorMessage {
                Text(msg).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: 420)
    }
}
