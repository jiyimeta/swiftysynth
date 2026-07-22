import AVFoundation
import SwiftUI
import SwiftySynth

@MainActor
final class SynthEngine: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var soundFontName: String?
    @Published private(set) var midiName: String?
    @Published var layerCount: Int = 1 {
        didSet { if isPlaying && layerCount != oldValue { restart() } }
    }

    /// SF2 note-on modulators — the piano fix. On MuseScore_General this is the
    /// A/B switch: OFF renders Acoustic Grand Piano ~25 dB too quiet (the bug),
    /// ON restores a natural balance. Toggling live restarts playback.
    @Published var enableModulators: Bool = true {
        didSet { if isPlaying && enableModulators != oldValue { restart() } }
    }

    /// Which generated test phrase drives playback.
    @Published var testSignal: TestSignals.Kind = .pianoPhrase {
        didSet {
            guard testSignal != oldValue else { return }
            loadTestSignal()
            if isPlaying { restart() }
        }
    }

    /// SoundFonts the picker offers (bundled `Sounds/*.sf2`, plus any opened
    /// via the file importer).
    @Published private(set) var availableSoundFonts: [URL]
    @Published var selectedSoundFont: URL? {
        didSet {
            guard selectedSoundFont != oldValue, let url = selectedSoundFont else { return }
            loadSoundFont(url: url)
        }
    }

    let sampleRate = 44_100
    private let maxFrames = 16_384

    private var soundFont: SoundFont?
    private var midiFile: MidiFile?
    private var engine: AVAudioEngine?
    private var core: RenderCore?

    /// The running core's stats (nil when stopped).
    var stats: RenderStats? { core?.stats }

    init() {
        availableSoundFonts = LoudnessProbe.bundledSoundFontURLs()
        // Prefer MuseScore_General — the font whose Acoustic Grand Piano exposes
        // the modulator bug — so the fix is audible on first launch.
        let initial = availableSoundFonts.first { $0.lastPathComponent.hasPrefix("MuseScore") }
            ?? ResourceLocator.soundFontURL()
            ?? availableSoundFonts.first
        if let initial {
            if !availableSoundFonts.contains(initial) { availableSoundFonts.append(initial) }
            selectedSoundFont = initial // didSet does not fire during init
            loadSoundFont(url: initial)
        } else {
            errorMessage = "SoundFont が見つかりません。Sounds/ に *.sf2 を置くか Open SoundFont… で指定してください。"
        }
        loadTestSignal()
    }

    func loadSoundFont(url: URL) {
        do {
            soundFont = try SoundFont(url: url)
            soundFontName = url.lastPathComponent
            errorMessage = nil
            if isPlaying { restart() }
        } catch {
            errorMessage = "SoundFont 読み込み失敗: \(error)"
        }
    }

    /// Add an externally-picked SoundFont to the list and select it.
    func openExternalSoundFont(url: URL) {
        if !availableSoundFonts.contains(url) { availableSoundFonts.append(url) }
        selectedSoundFont = url
    }

    /// Regenerate the in-memory MIDI for the selected test signal.
    private func loadTestSignal() {
        do {
            midiFile = try TestSignals.midi(for: testSignal)
            midiName = testSignal.rawValue
            errorMessage = nil
        } catch {
            errorMessage = "テスト信号生成失敗: \(error)"
        }
    }

    func loadMidi(url: URL) {
        do {
            midiFile = try MidiFile(url: url)
            midiName = url.lastPathComponent
            errorMessage = nil
            if isPlaying { restart() }
        } catch {
            errorMessage = "MIDI 読み込み失敗: \(error)"
        }
    }

    func play() { guard !isPlaying else { return }; start() }

    func stop() {
        engine?.stop()
        engine = nil
        core = nil
        isPlaying = false
    }

    private func restart() { stop(); start() }

    private func start() {
        guard let soundFont else { errorMessage = "SoundFont が未ロードです。"; return }
        guard let midiFile else { errorMessage = "MIDI が未ロードです。"; return }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            #endif
            let core = try RenderCore(
                soundFont: soundFont, midiFile: midiFile,
                layerCount: layerCount, sampleRate: sampleRate, maxFrames: maxFrames,
                enableModulators: enableModulators)
            let node = SynthEngine.makeSourceNode(core: core, sampleRate: Double(sampleRate))
            let engine = AVAudioEngine()
            engine.attach(node)
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            self.core = core
            self.engine = engine
            isPlaying = true
            errorMessage = nil
        } catch {
            errorMessage = "再生開始に失敗: \(error)"
            isPlaying = false
        }
    }

    /// MUST be `nonisolated static`: a render block created in a @MainActor
    /// context inherits MainActor isolation and traps EXC_BREAKPOINT on the
    /// audio thread (spike §8).
    nonisolated static func makeSourceNode(core: RenderCore, sampleRate: Double) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let startTicks = mach_absolute_time()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard abl.count >= 2, let rawL = abl[0].mData, let rawR = abl[1].mData else {
                return kAudioUnitErr_InvalidParameter
            }
            let left = UnsafeMutableBufferPointer(
                start: rawL.assumingMemoryBound(to: Float.self), count: frames)
            let right = UnsafeMutableBufferPointer(
                start: rawR.assumingMemoryBound(to: Float.self), count: frames)
            core.render(left: left, right: right, frames: frames)
            core.stats.record(
                nanos: MachTime.toNanos(mach_absolute_time() - startTicks),
                frames: frames, activeVoices: core.activeVoices)
            return noErr
        }
    }
}
