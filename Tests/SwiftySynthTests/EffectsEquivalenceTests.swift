import Foundation
import Testing
@testable import SwiftySynth

/// G2-fx acceptance thresholds — CALIBRATED, not copied (spec §7).
/// Initialized at the dry G2 bar. If the measured faithful-vs-faithful f32
/// drift of the two Freeverb/chorus implementations exceeds it, the plan's
/// Task-6 decision table applies: the numbers are REPORTED to the user and
/// the bar is re-set in the gap between the measured drift and the bug
/// regime only after approval — never silently loosened. Any change to
/// these values MUST update this comment with the measured basis and date.
enum G2FXBar {
    static let maxAbs = 1e-4
    static let worstWindowRMS = 3e-5
    static let snr = 80.0
    static let zeroLagCorrelation = 0.99999
}

@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct EffectsEquivalenceTests {
    /// **G2-fx (end-to-end)** — the committed effects-on GM stream (default
    /// + explicit reverb sends, chorus via CC 0x5D incl. mid-note ramps,
    /// percussion, a 2 s pure-tail region), rendered with reverb + chorus
    /// enabled, matches the rustysynth reference WAV per stereo channel
    /// under the calibrated G2FXBar, no lag search. Component correctness
    /// is pinned separately by ReverbTests/ChorusTests (hand-derived — no
    /// rustysynth component taps exist; locked decision). The sidecar's
    /// message frames are the shared chunk boundaries, so internal block-64
    /// phase matches by construction.
    @Test func effectsOnRenderMatchesOracle() throws {
        let sidecarURL = try #require(Fixtures.url("multi-gm-fx", "json"))
        let sidecar = try JSONDecoder().decode(MultiRenderSidecar.self, from: Data(contentsOf: sidecarURL))
        // Like-for-like guard: the vector's parameters are what this test assumes.
        try #require(sidecar.sampleRate == 44_100)
        try #require(sidecar.blockSize == 64)
        try #require(sidecar.maximumPolyphony == 64)
        try #require(sidecar.enableReverbAndChorus == true)
        try #require(sidecar.totalFrames == 220_500)
        try #require(!sidecar.messages.isEmpty)
        for i in 1..<sidecar.messages.count {
            try #require(
                sidecar.messages[i].frame >= sidecar.messages[i - 1].frame,
                "sidecar messages must be frame-ordered — they are the shared chunk boundaries")
        }
        try #require(sidecar.messages.last!.frame <= sidecar.totalFrames)

        // The local font must be byte-identical to the one the vectors came from.
        let fontData = try Data(contentsOf: FixtureSF2.url)
        try #require(
            sha256Hex(fontData) == sidecar.soundFontSha256,
            "local SF2 differs from the font the oracle vectors were generated from — regenerate the fixtures")

        let font = try SoundFont(data: fontData)
        let settings = try SynthesizerSettings(
            sampleRate: sidecar.sampleRate,
            blockSize: sidecar.blockSize,
            maximumPolyphony: sidecar.maximumPolyphony,
            enableReverbAndChorus: sidecar.enableReverbAndChorus)
        let synth = try Synthesizer(soundFont: font, settings: settings)
        synth.masterVolume = Float(sidecar.masterVolume)

        var left = [Float](repeating: 0, count: sidecar.totalFrames)
        var right = [Float](repeating: 0, count: sidecar.totalFrames)

        // Replay: render up to each message frame, apply, render the tail —
        // the identical loop the oracle's render_fx runs.
        var position = 0
        for message in sidecar.messages {
            if message.frame > position {
                renderInto(synth, &left, &right, position..<message.frame)
                position = message.frame
            }
            synth.processMidiMessage(
                channel: message.channel, command: message.command,
                data1: message.data1, data2: message.data2)
        }
        if position < sidecar.totalFrames {
            renderInto(synth, &left, &right, position..<sidecar.totalFrames)
        }

        let wavURL = try #require(Fixtures.url("multi-gm-fx", "wav"))
        let (refLeft, refRight) = try FloatWav.read(url: wavURL)
        try #require(refLeft.count == sidecar.totalFrames)

        for (name, ours, ref) in [("left", left, refLeft), ("right", right, refRight)] {
            let error = (0..<ref.count).map { Double(ours[$0]) - Double(ref[$0]) }
            let maxAbs = PCMMetrics.maxAbsDifference(ours, ref)
            let worstWindow = PCMMetrics.worstWindowRMS(error: error)
            let snr = PCMMetrics.snr(reference: ref, error: error)
            let correlation = PCMMetrics.zeroLagCorrelation(ours, ref)

            // Log measured numbers on pass AND fail (spec §7) — these are
            // the calibration record and go into the README gate table.
            print("G2-fx[\(name)] maxAbs=\(maxAbs) worstWindowRMS=\(worstWindow) snr=\(snr)dB zeroLagCorr=\(correlation)")

            #expect(maxAbs <= G2FXBar.maxAbs, "[\(name)] per-sample max error \(maxAbs) exceeds \(G2FXBar.maxAbs)")
            #expect(worstWindow <= G2FXBar.worstWindowRMS, "[\(name)] worst 4096-window RMS \(worstWindow) exceeds \(G2FXBar.worstWindowRMS)")
            #expect(snr >= G2FXBar.snr, "[\(name)] SNR \(snr) dB below \(G2FXBar.snr) dB")
            #expect(correlation >= G2FXBar.zeroLagCorrelation, "[\(name)] zero-lag correlation \(correlation) below \(G2FXBar.zeroLagCorrelation)")
        }
    }
}
