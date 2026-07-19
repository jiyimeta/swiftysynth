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

    let sampleRate = 44_100
    private let maxFrames = 16_384

    private var soundFont: SoundFont?
    private var midiFile: MidiFile?
    private var engine: AVAudioEngine?
    private var core: RenderCore?

    /// The running core's stats (nil when stopped).
    var stats: RenderStats? { core?.stats }

    init() {
        if let url = ResourceLocator.soundFontURL() {
            loadSoundFont(url: url)
        } else {
            errorMessage = "SoundFont が見つかりません。Sounds/ に GeneralUser-GS.sf2 を置くか SWIFTYSYNTH_SF2 を設定してください。"
        }
        if let url = ResourceLocator.sampleMidiURL() { loadMidi(url: url) }
    }

    func loadSoundFont(url: URL) {
        do {
            soundFont = try SoundFont(url: url)
            soundFontName = url.lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = "SoundFont 読み込み失敗: \(error)"
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
                layerCount: layerCount, sampleRate: sampleRate, maxFrames: maxFrames)
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
