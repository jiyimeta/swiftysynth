import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SynthEngine()
    @State private var snapshot = RenderStats.Snapshot(
        currentPercent: 0, maxPercent: 0, activeVoices: 0)

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Text("SwiftySynth Example").font(.title2).bold()
            buildBadge
            meter
            HStack {
                Text("active voices: \(snapshot.activeVoices)")
                Spacer()
                Text(String(format: "max: %.0f%%", snapshot.maxPercent))
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)

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
        .onReceive(ticker) { _ in
            if engine.isPlaying, let s = engine.stats?.snapshot() {
                snapshot = s
            } else if !engine.isPlaying {
                snapshot = RenderStats.Snapshot(currentPercent: 0, maxPercent: 0, activeVoices: 0)
            }
        }
    }

    @ViewBuilder private var buildBadge: some View {
        #if DEBUG
        Label("Build: Debug — unoptimized deps, expect dropouts", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange).font(.caption)
        #else
        Label("Build: Release", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green).font(.caption)
        #endif
    }

    private var meterColor: Color {
        snapshot.currentPercent > 100 ? .red : (snapshot.currentPercent > 70 ? .orange : .green)
    }

    private var meter: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.0f%%", snapshot.currentPercent))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(meterColor)
                .monospacedDigit()
            Text("of real-time budget").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 6).fill(meterColor)
                        .frame(width: min(1.0, snapshot.currentPercent / 100) * geo.size.width)
                }
            }
            .frame(height: 16)
        }
    }
}
