import Foundation
import Testing
@testable import SwiftySynth

struct MultiMidiMessage: Decodable {
    let frame: Int
    let channel: Int
    let command: Int
    let data1: Int
    let data2: Int
}

struct MultiRenderSidecar: Decodable {
    let sampleRate: Int
    let blockSize: Int
    let maximumPolyphony: Int
    let enableReverbAndChorus: Bool
    let masterVolume: Double
    let totalFrames: Int
    let rustysynthVersion: String
    let soundFontSha256: String
    let messages: [MultiMidiMessage]
}

@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct MultichannelEquivalenceTests {
    /// **G2-multi** — the committed multichannel GM stream (program change,
    /// CC volume/pan/expression, RPN + pitch bend, percussion channel 9),
    /// rendered dry, matches the rustysynth reference WAV under all §7
    /// criteria, per stereo channel, no lag search. The sidecar's message
    /// frames are the shared chunk boundaries — both sides render identical
    /// spans, so internal block phase matches by construction.
    @Test func multichannelDryRenderMatchesOracle() throws {
        let sidecarURL = try #require(Fixtures.url("multi-gm-dry", "json"))
        let sidecar = try JSONDecoder().decode(MultiRenderSidecar.self, from: Data(contentsOf: sidecarURL))
        // Like-for-like guard: the vector's parameters are what this test assumes.
        try #require(sidecar.sampleRate == 44_100)
        try #require(sidecar.blockSize == 64)
        try #require(sidecar.maximumPolyphony == 64)
        try #require(sidecar.enableReverbAndChorus == false)
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
        // the identical loop the oracle's render_multi runs.
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

        let wavURL = try #require(Fixtures.url("multi-gm-dry", "wav"))
        let (refLeft, refRight) = try FloatWav.read(url: wavURL)
        try #require(refLeft.count == sidecar.totalFrames)

        for (name, ours, ref) in [("left", left, refLeft), ("right", right, refRight)] {
            let error = (0..<ref.count).map { Double(ours[$0]) - Double(ref[$0]) }
            let maxAbs = PCMMetrics.maxAbsDifference(ours, ref)
            let worstWindow = PCMMetrics.worstWindowRMS(error: error)
            let snr = PCMMetrics.snr(reference: ref, error: error)
            let correlation = PCMMetrics.zeroLagCorrelation(ours, ref)

            // Log measured numbers on pass AND fail (spec §7).
            print("G2-multi[\(name)] maxAbs=\(maxAbs) worstWindowRMS=\(worstWindow) snr=\(snr)dB zeroLagCorr=\(correlation)")

            #expect(maxAbs <= 1e-4, "[\(name)] per-sample max error \(maxAbs) exceeds 1e-4")
            #expect(worstWindow <= 3e-5, "[\(name)] worst 4096-window RMS \(worstWindow) exceeds 3e-5")
            #expect(snr >= 80, "[\(name)] SNR \(snr) dB below 80 dB")
            #expect(correlation >= 0.99999, "[\(name)] zero-lag correlation \(correlation) below 0.99999")
        }
    }
}
