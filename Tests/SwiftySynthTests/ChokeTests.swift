import Foundation
import Testing
@testable import SwiftySynth

/// `Synthesizer.choke(key:on:)` — the extension beyond MeltySynth that stops a key's voices in
/// `Synthesizer.chokeReleaseTime`, whatever the font's own release and whatever the hold pedal says.
///
/// The synthetic font loops its sample (54 = 1) so a voice sustains indefinitely, and gives it a ~101 s release
/// (38 = 8000 timecents) so an ordinary note-off leaves it audible for the whole test — the shape of a crash cymbal in
/// GeneralUser-GS (48.5 s). Effects are off so no reverb tail muddies the levels.
struct ChokeTests {
    private static let sampleRate = 44_100
    private static let block = 64

    private static func timecents(_ value: Int16) -> UInt16 { UInt16(bitPattern: value) }

    private func makeSynth(release: Int16 = 8000, attack: Int16? = nil) throws -> Synthesizer {
        var generators: [(type: UInt16, value: UInt16)] = [(54, 1), (38, Self.timecents(release))]
        if let attack { generators.append((34, Self.timecents(attack))) }
        generators.append((53, 0))
        let font = try SoundFont(data: SyntheticSF2.minimal(instrumentGenerators: generators))
        let settings = try SynthesizerSettings(sampleRate: Self.sampleRate, enableReverbAndChorus: false)
        return try Synthesizer(soundFont: font, settings: settings)
    }

    /// Renders `seconds` in 64-frame blocks and returns the left channel.
    private func render(_ synth: Synthesizer, seconds: Double) -> [Float] {
        let frames = Int(seconds * Double(Self.sampleRate)) / Self.block * Self.block
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        renderInto(synth, &left, &right, 0..<frames)
        return left
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float { samples.map(abs).max() ?? 0 }

    private func decibels(_ ratio: Float) -> Float { 20 * log10(max(ratio, 1e-12)) }

    /// The level of the 10 ms window that starts `offset` seconds into `samples`.
    private func window(_ samples: [Float], at offset: Double) -> ArraySlice<Float> {
        let start = Int(offset * Double(Self.sampleRate))
        return samples[start..<min(start + 441, samples.count)]
    }

    @Test func chokeSilencesWithinChokeTime() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        let before = render(synth, seconds: 0.2)
        synth.choke(key: 60, on: 0)
        let after = render(synth, seconds: 0.2)

        let reference = rms(before.suffix(441))
        #expect(decibels(rms(window(after, at: 0.06)) / reference) < -60)
    }

    @Test func noteOffAloneLeavesTheLongReleaseRinging() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        let before = render(synth, seconds: 0.2)
        synth.noteOff(key: 60, on: 0)
        let after = render(synth, seconds: 0.2)

        #expect(decibels(rms(window(after, at: 0.06)) / rms(before.suffix(441))) > -6)
    }

    @Test func chokeIsContinuous() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        let before = render(synth, seconds: 0.2)
        synth.choke(key: 60, on: 0)
        let after = render(synth, seconds: 0.01)

        let lastPeak = peak(before.suffix(Self.block)[...])
        #expect(peak(after.prefix(Self.block)[...]) <= lastPeak * 1.01)
        // A fade, not a cut: the first block keeps most of the level, and 5 ms in it is still well above silence.
        #expect(peak(after.prefix(Self.block)[...]) >= lastPeak * 0.8)
        #expect(decibels(rms(window(after, at: 0.005)) / rms(before.suffix(441))) > -30)
    }

    @Test func chokeAfterAPedalHeldNoteOffStillStops() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 64, data2: 127)
        synth.noteOn(key: 60, velocity: 100, on: 0)
        let before = render(synth, seconds: 0.2)
        synth.noteOff(key: 60, on: 0)  // held by the pedal
        _ = render(synth, seconds: 0.05)
        synth.choke(key: 60, on: 0)
        let after = render(synth, seconds: 0.2)

        #expect(decibels(rms(window(after, at: 0.06)) / rms(before.suffix(441))) < -60)
    }

    @Test func chokeIgnoresHoldPedal() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 64, data2: 127)
        synth.noteOn(key: 60, velocity: 100, on: 0)
        let before = render(synth, seconds: 0.2)
        synth.choke(key: 60, on: 0)
        let after = render(synth, seconds: 0.2)

        #expect(decibels(rms(window(after, at: 0.06)) / rms(before.suffix(441))) < -60)
    }

    @Test func chokeLeavesOtherKeys() throws {
        let choked = try makeSynth()
        choked.noteOn(key: 60, velocity: 100, on: 0)
        choked.noteOn(key: 67, velocity: 100, on: 0)
        _ = render(choked, seconds: 0.2)
        choked.choke(key: 60, on: 0)
        // Once key 60 has died away, what remains must be a key 67 played alone.
        let referenceAlone = try makeSynth()
        referenceAlone.noteOn(key: 67, velocity: 100, on: 0)
        _ = render(referenceAlone, seconds: 0.2)

        let tailChoked = render(choked, seconds: 0.3).suffix(4410)
        let tailAlone = render(referenceAlone, seconds: 0.3).suffix(4410)
        #expect(abs(decibels(rms(tailChoked) / rms(tailAlone))) < 0.1)
    }

    @Test func chokeStopsOverlappingHits() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        _ = render(synth, seconds: 0.1)
        synth.noteOn(key: 60, velocity: 100, on: 0)
        _ = render(synth, seconds: 0.1)
        #expect(synth.activeVoiceCount == 2)
        synth.choke(key: 60, on: 0)
        _ = render(synth, seconds: 0.1)
        #expect(synth.activeVoiceCount == 0)
    }

    @Test func chokeKeepsAFasterRelease() throws {
        let choked = try makeSynth(release: -6000)
        let plain = try makeSynth(release: -6000)
        for synth in [choked, plain] {
            synth.noteOn(key: 60, velocity: 100, on: 0)
            _ = render(synth, seconds: 0.2)
            synth.noteOff(key: 60, on: 0)
            _ = render(synth, seconds: 0.005)
        }
        choked.choke(key: 60, on: 0)
        #expect(render(choked, seconds: 0.1) == render(plain, seconds: 0.1))
    }

    @Test func chokeRightAfterNoteOn() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        synth.choke(key: 60, on: 0)
        let out = render(synth, seconds: 0.15)
        #expect(peak(out.prefix(Self.block)[...]) > 0)
        #expect(synth.activeVoiceCount == 0)
    }

    @Test func chokeDuringAttack() throws {
        let synth = try makeSynth(attack: 0)  // 0 timecents = a 1 s attack
        synth.noteOn(key: 60, velocity: 100, on: 0)
        let before = render(synth, seconds: 0.1)
        synth.choke(key: 60, on: 0)
        let after = render(synth, seconds: 0.01)

        #expect(peak(after.prefix(Self.block)[...]) <= peak(before.suffix(Self.block)[...]) * 1.01)
    }

    @Test func chokeNoOpCases() throws {
        let probed = try makeSynth()
        let plain = try makeSynth()
        for synth in [probed, plain] { synth.noteOn(key: 60, velocity: 100, on: 0) }
        probed.choke(key: 61, on: 0)
        probed.choke(key: 60, on: 1)
        probed.choke(key: 60, on: -1)
        probed.choke(key: 60, on: 16)
        #expect(render(probed, seconds: 0.2) == render(plain, seconds: 0.2))
    }
}
