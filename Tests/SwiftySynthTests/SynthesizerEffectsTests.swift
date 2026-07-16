import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic effects-bus wiring tests over the synthetic font (loop-enabled
/// so one voice sustains indefinitely; the synthetic instrument has no
/// effects-send generators, so instrument sends are 0 and the CHANNEL sends
/// fully control the bus: reverb defaults to 40/127, chorus to 0).
/// Component numerics are ReverbTests/ChorusTests' job and oracle
/// equivalence is EffectsEquivalenceTests' (G2-fx) — these pin the ROUTING:
/// the allocation policy, both send paths, the return mix, and reset's mute.
struct SynthesizerEffectsTests {
    private func makeSynth(effectsOn: Bool) throws -> Synthesizer {
        let font = try SoundFont(
            data: SyntheticSF2.minimal(instrumentGenerators: [(54, 1), (53, 0)]))  // continuous loop
        let settings = try SynthesizerSettings(sampleRate: 44_100, enableReverbAndChorus: effectsOn)
        return try Synthesizer(soundFont: font, settings: settings)
    }

    private func render(_ synth: Synthesizer, frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        renderInto(synth, &left, &right, 0..<frames)
        return (left, right)
    }

    /// Spec §8: effects state exists iff enabled — allocated at init, never
    /// lazily.
    @Test func effectsAreAllocatedOnlyWhenEnabled() throws {
        #expect(try makeSynth(effectsOn: true).effects != nil)
        #expect(try makeSynth(effectsOn: false).effects == nil)
    }

    /// The channel-default reverb send (40/127) makes wet output diverge
    /// from dry — but not before the shortest comb arrival (1116 samples):
    /// until then the effects return is exactly zero and both renders are
    /// bit-identical (the dry mix path is untouched by this phase).
    @Test func defaultReverbSendDivergesAfterTheCombPreDelay() throws {
        let wet = try makeSynth(effectsOn: true)
        let dry = try makeSynth(effectsOn: false)
        wet.noteOn(key: 60, velocity: 100, on: 0)
        dry.noteOn(key: 60, velocity: 100, on: 0)
        let w = render(wet, frames: 8_820)
        let d = render(dry, frames: 8_820)

        #expect(Array(w.left[0..<1_116]) == Array(d.left[0..<1_116]),
                "no effects return may land before the shortest comb tuning")
        #expect(w.left != d.left)
        #expect(w.right != d.right)
    }

    /// Zeroed sends ⇒ the effects bus carries exactly zero energy ⇒ the
    /// effects-on render is BIT-IDENTICAL to dry. Pins that the send gains
    /// really gate the bus and that a silent bus contributes +0 to the mix.
    @Test func zeroedSendsMakeEffectsOnOutputIdenticalToDry() throws {
        let wet = try makeSynth(effectsOn: true)
        let dry = try makeSynth(effectsOn: false)
        for synth in [wet, dry] {
            synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x5B, data2: 0)  // reverb send 0
            synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x5D, data2: 0)  // chorus send 0
            synth.noteOn(key: 60, velocity: 100, on: 0)
        }
        let w = render(wet, frames: 8_192)
        let d = render(dry, frames: 8_192)
        #expect(w.left == d.left)
        #expect(w.right == d.right)
    }

    /// Chorus is OFF by default (channel send 0) — raising CC 0x5D must
    /// change the output even with the reverb send zeroed. Pins the chorus
    /// half of the routing independently of the reverb half.
    @Test func chorusSendActivatesTheChorusBus() throws {
        let withChorus = try makeSynth(effectsOn: true)
        let reference = try makeSynth(effectsOn: true)
        for synth in [withChorus, reference] {
            synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x5B, data2: 0)  // isolate chorus
        }
        withChorus.processMidiMessage(channel: 0, command: 0xB0, data1: 0x5D, data2: 100)
        withChorus.noteOn(key: 60, velocity: 100, on: 0)
        reference.noteOn(key: 60, velocity: 100, on: 0)
        let a = render(withChorus, frames: 2_048)
        let b = render(reference, frames: 2_048)
        #expect(a.left != b.left)
        #expect(a.right != b.right)
    }

    /// The previously deferred reset() effects mute: after reset, a synth
    /// whose comb banks were ringing must render EXACT silence — voices are
    /// cleared, and the reverb/chorus state is muted, so nothing rings on.
    @Test func resetMutesTheEffectsTail() throws {
        let wet = try makeSynth(effectsOn: true)
        wet.noteOn(key: 60, velocity: 100, on: 0)
        let before = render(wet, frames: 8_820)   // energize the comb banks (>1116 samples)
        #expect(before.left.contains { $0 != 0 })

        wet.reset()
        let after = render(wet, frames: 8_820)
        #expect(after.left.allSatisfy { $0 == 0 },
                "reset must mute the reverb/chorus state — no ringing tail")
        #expect(after.right.allSatisfy { $0 == 0 })
    }
}
