import Foundation
import Testing
@testable import MeltySynth

struct RenderSidecar: Decodable {
    let bank: Int
    let patch: Int
    let key: Int
    let velocity: Int
    let sampleRate: Int
    let noteOnFrame: Int
    let noteOffFrame: Int
    let totalFrames: Int
    let masterVolume: Double
    let blockSize: Int
    let maximumPolyphony: Int
    let enableReverbAndChorus: Bool
    let rustysynthVersion: String
    let soundFontSha256: String
}

@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct PCMEquivalenceTests {
    /// **G2** — the fixture note rendered by Swift matches the rustysynth reference WAV
    /// under all three §7 criteria, per channel, with no alignment search.
    @Test func singleNoteMatchesOracle() throws {
        let sidecarURL = try #require(Fixtures.url("note-c4-vel100", "json"))
        let sidecar = try JSONDecoder().decode(RenderSidecar.self, from: Data(contentsOf: sidecarURL))
        // Like-for-like guard: the vector's parameters are what this test assumes.
        try #require(sidecar.bank == 0)
        try #require(sidecar.patch == 0)
        try #require(sidecar.key == 60)
        try #require(sidecar.velocity == 100)
        try #require(sidecar.sampleRate == 44_100)
        try #require(sidecar.noteOnFrame == 0)
        try #require(sidecar.noteOffFrame == 88_200)
        try #require(sidecar.totalFrames == 220_500)
        try #require(sidecar.blockSize == 64)
        try #require(sidecar.enableReverbAndChorus == false)

        // The local font must be byte-identical to the one the vectors came from.
        let fontData = try Data(contentsOf: FixtureSF2.url)
        try #require(
            sha256Hex(fontData) == sidecar.soundFontSha256,
            "local SF2 differs from the font the oracle vectors were generated from — regenerate the fixtures")

        let font = try SoundFont(data: fontData)
        let synth = try Synthesizer(
            soundFont: font, sampleRate: sidecar.sampleRate, maximumPolyphony: sidecar.maximumPolyphony)
        synth.masterVolume = Float(sidecar.masterVolume)

        var left = [Float](repeating: 0, count: sidecar.totalFrames)
        var right = [Float](repeating: 0, count: sidecar.totalFrames)

        // Two-chunk render, frame-aligned by construction — identical to the oracle's.
        synth.noteOn(key: sidecar.key, velocity: sidecar.velocity)
        renderInto(synth, &left, &right, 0..<sidecar.noteOffFrame)
        synth.noteOff(key: sidecar.key)
        renderInto(synth, &left, &right, sidecar.noteOffFrame..<sidecar.totalFrames)

        let wavURL = try #require(Fixtures.url("note-c4-vel100", "wav"))
        let (refLeft, refRight) = try FloatWav.read(url: wavURL)
        try #require(refLeft.count == sidecar.totalFrames)

        for (name, ours, ref) in [("left", left, refLeft), ("right", right, refRight)] {
            let error = (0..<ref.count).map { Double(ours[$0]) - Double(ref[$0]) }
            let maxAbs = PCMMetrics.maxAbsDifference(ours, ref)
            let worstWindow = PCMMetrics.worstWindowRMS(error: error)
            let snr = PCMMetrics.snr(reference: ref, error: error)
            let correlation = PCMMetrics.zeroLagCorrelation(ours, ref)

            // Log measured numbers on pass AND fail (spec §7).
            print("G2[\(name)] maxAbs=\(maxAbs) worstWindowRMS=\(worstWindow) snr=\(snr)dB zeroLagCorr=\(correlation)")

            #expect(maxAbs <= 1e-4, "[\(name)] per-sample max error \(maxAbs) exceeds 1e-4")
            #expect(worstWindow <= 3e-5, "[\(name)] worst 4096-window RMS \(worstWindow) exceeds 3e-5")
            #expect(snr >= 80, "[\(name)] SNR \(snr) dB below 80 dB")
            #expect(correlation >= 0.99999, "[\(name)] zero-lag correlation \(correlation) below 0.99999")
        }
    }
}
