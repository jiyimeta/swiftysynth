import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = SynthEngine()
    @State private var snapshot = RenderStats.Snapshot(
        currentPercent: 0, maxPercent: 0, activeVoices: 0)
    @State private var showingMidiImporter = false
    @State private var showingSoundFontImporter = false
    @State private var loudnessReport: String?
    @State private var measuring = false

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

            pianoFixPanel

            Stepper("layers: \(engine.layerCount)", value: $engine.layerCount, in: 1...8)
                .font(.callout)

            HStack {
                Button(engine.isPlaying ? "Stop" : "Play") {
                    engine.isPlaying ? engine.stop() : engine.play()
                }
                .buttonStyle(.borderedProminent)
                Button("Open MIDI…") { showingMidiImporter = true }
                Button("Open SoundFont…") { showingSoundFontImporter = true }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SoundFont: \(engine.soundFontName ?? "— (drop one into Sounds/)")")
                Text("MIDI: \(engine.midiName ?? "—")")
            }
            .font(.caption).foregroundStyle(.secondary)

            loudnessPanel

            if let msg = engine.errorMessage {
                Text(msg).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: 460)
        .onReceive(ticker) { _ in
            if engine.isPlaying, let s = engine.stats?.snapshot() {
                snapshot = s
            } else if !engine.isPlaying {
                snapshot = RenderStats.Snapshot(currentPercent: 0, maxPercent: 0, activeVoices: 0)
            }
        }
        .fileImporter(isPresented: $showingMidiImporter, allowedContentTypes: [.midi]) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            engine.loadMidi(url: url)
        }
        .fileImporter(
            isPresented: $showingSoundFontImporter,
            allowedContentTypes: [UTType(filenameExtension: "sf2") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            engine.openExternalSoundFont(url: url)
        }
    }

    /// The star of the harness: flip SF2 note-on modulators and hear the piano
    /// fix. Also picks the test phrase and the SoundFont (MuseScore_General is
    /// the one that exposes the bug).
    private var pianoFixPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $engine.enableModulators) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SF2 note-on modulators (piano fix)").bold()
                        Text(engine.enableModulators
                            ? "ON — piano at its intended level"
                            : "OFF — reproduces the near-silent piano bug")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Test signal", selection: $engine.testSignal) {
                    ForEach(TestSignals.Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                Picker("SoundFont", selection: $engine.selectedSoundFont) {
                    ForEach(engine.availableSoundFonts, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
            }
            .padding(4)
        }
    }

    /// Loudness A/B: measures piano(prog 0) with modulators OFF vs ON against
    /// bass(prog 33) across the bundled SoundFonts, so the dBFS gap that makes
    /// piano-switched staves quiet — and the fix — can be read as numbers.
    private var loudnessPanel: some View {
        VStack(spacing: 6) {
            Button(measuring ? "Measuring…" : "Measure loudness A/B (piano OFF/ON vs bass)") {
                measuring = true
                loudnessReport = nil
                Task.detached {
                    let text = LoudnessProbe.report()
                    await MainActor.run {
                        loudnessReport = text
                        measuring = false
                    }
                }
            }
            .disabled(measuring)
            if let report = loudnessReport {
                ScrollView(.horizontal) {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
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
