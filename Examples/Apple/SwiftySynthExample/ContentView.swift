import SwiftUI

struct ContentView: View {
    private let soundFont = ResourceLocator.soundFontURL()
    private let midi = ResourceLocator.sampleMidiURL()

    var body: some View {
        VStack(spacing: 12) {
            Text("SwiftySynth Example").font(.title2).bold()
            Text("SoundFont: \(soundFont?.lastPathComponent ?? "— (drop one into Sounds/)")")
            Text("MIDI: \(midi?.lastPathComponent ?? "—")")
        }
        .font(.callout)
        .padding()
    }
}
