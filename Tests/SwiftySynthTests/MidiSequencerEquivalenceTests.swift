import Foundation
import Testing
@testable import SwiftySynth

/// The render-midi sidecar (schema from Task 2).
struct MidiSeqSidecar: Decodable {
    let sampleRate: Int
    let blockSize: Int
    let maximumPolyphony: Int
    let enableReverbAndChorus: Bool
    let masterVolume: Double
    let totalFrames: Int
    let loop: Bool
    let loopType: String
    let speed: Double
    let rustysynthVersion: String
    let soundFontSha256: String
    let midiSha256: String
}

/// G-midi e2e acceptance thresholds — the UNCHANGED dry G2 bar (spec §7
/// G-midi; plan Global Constraints: P2's G2-fx calibration landed case 1 —
/// measured effects-on drift ≈ 123 dB SNR, maxAbs ≈ 3e-7 — so effects add
/// no tolerance risk and the gate exercises the full production path). If
/// this gate fails only in the magnitudes (clean drift regime, structure
/// green), REPORT the measured numbers to the user before considering any
/// threshold change — never loosen silently.
enum GMidiBar {
    static let maxAbs = 1e-4
    static let worstWindowRMS = 3e-5
    static let snr = 80.0
    static let zeroLagCorrelation = 0.99999
}

@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct MidiSequencerEquivalenceTests {
    /// **G-midi (e2e)** — the committed GM song through the Swift
    /// MidiFileSequencer (FinalFantasy loop markers, loop ON: one full
    /// pass, the ≈4.4 s rewind incl. noteOffAll on the still-held strings
    /// note, the replayed loop region) vs the rustysynth sequencer's
    /// reference WAV, effects ON, per channel, no lag search. Rendered in
    /// 997-frame chunks against the oracle's single call — the sequencer's
    /// internal block walk makes event placement chunk-independent, so any
    /// mismatch is real.
    @Test func sequencerRenderMatchesOracle() throws {
        let sidecarURL = try #require(Fixtures.url("midi-gm-seq", "json"))
        let sidecar = try JSONDecoder().decode(MidiSeqSidecar.self, from: Data(contentsOf: sidecarURL))
        // Like-for-like guard: the vector's parameters are what this test assumes.
        try #require(sidecar.sampleRate == 44_100)
        try #require(sidecar.blockSize == 64)
        try #require(sidecar.maximumPolyphony == 64)
        try #require(sidecar.enableReverbAndChorus == true)
        try #require(sidecar.totalFrames == 220_500)
        try #require(sidecar.loop == true)
        try #require(sidecar.loopType == "finalfantasy")
        try #require(sidecar.speed == 1.0)

        // Both inputs must be byte-identical to what the oracle rendered.
        let fontData = try Data(contentsOf: FixtureSF2.url)
        try #require(
            sha256Hex(fontData) == sidecar.soundFontSha256,
            "local SF2 differs from the font the oracle vector was generated from — regenerate the fixtures")
        let midURL = try #require(Fixtures.url("midi-gm-song", "mid"))
        let midData = try Data(contentsOf: midURL)
        try #require(
            sha256Hex(midData) == sidecar.midiSha256,
            "committed .mid differs from the one the oracle vector was generated from — regenerate the fixtures")

        let font = try SoundFont(data: fontData)
        let settings = try SynthesizerSettings(
            sampleRate: sidecar.sampleRate,
            blockSize: sidecar.blockSize,
            maximumPolyphony: sidecar.maximumPolyphony,
            enableReverbAndChorus: sidecar.enableReverbAndChorus)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        synth.masterVolume = Float(sidecar.masterVolume)

        let midi = try MidiFile(data: midData, loopType: .finalFantasy)
        let sequencer = MidiFileSequencer(synthesizer: synth)
        sequencer.play(midi, loop: sidecar.loop)

        var left = [Float](repeating: 0, count: sidecar.totalFrames)
        var right = [Float](repeating: 0, count: sidecar.totalFrames)
        var position = 0
        while position < sidecar.totalFrames {
            let n = min(997, sidecar.totalFrames - position)
            seqRenderInto(sequencer, &left, &right, position..<(position + n))
            position += n
        }
        #expect(!sequencer.isAtEnd, "looping playback is never at end")

        let wavURL = try #require(Fixtures.url("midi-gm-seq", "wav"))
        let (refLeft, refRight) = try FloatWav.read(url: wavURL)
        try #require(refLeft.count == sidecar.totalFrames)

        for (name, ours, ref) in [("left", left, refLeft), ("right", right, refRight)] {
            let error = (0..<ref.count).map { Double(ours[$0]) - Double(ref[$0]) }
            let maxAbs = PCMMetrics.maxAbsDifference(ours, ref)
            let worstWindow = PCMMetrics.worstWindowRMS(error: error)
            let snr = PCMMetrics.snr(reference: ref, error: error)
            let correlation = PCMMetrics.zeroLagCorrelation(ours, ref)

            // Log measured numbers on pass AND fail (spec §7) — these go
            // into the README gate table.
            print("G-midi-e2e[\(name)] maxAbs=\(maxAbs) worstWindowRMS=\(worstWindow) snr=\(snr)dB zeroLagCorr=\(correlation)")

            #expect(maxAbs <= GMidiBar.maxAbs, "[\(name)] per-sample max error \(maxAbs) exceeds \(GMidiBar.maxAbs)")
            #expect(worstWindow <= GMidiBar.worstWindowRMS, "[\(name)] worst 4096-window RMS \(worstWindow) exceeds \(GMidiBar.worstWindowRMS)")
            #expect(snr >= GMidiBar.snr, "[\(name)] SNR \(snr) dB below \(GMidiBar.snr) dB")
            #expect(correlation >= GMidiBar.zeroLagCorrelation, "[\(name)] zero-lag correlation \(correlation) below \(GMidiBar.zeroLagCorrelation)")
        }
    }
}
