import Foundation

/// The SF2-spec "default modulators" (§8.4) implicitly attached to a preset/instrument zone
/// whenever it has no explicit modulator list of its own (SF2 §7.4/§8.4).
enum DefaultModulators {
    /// Default #1 (SF2 §8.4.1): MIDI note-on velocity to initial attenuation, a concave,
    /// maxToMin, unipolar transform with amount 960 (its `amountSource` is `.none`, i.e.
    /// unmodulated, and its transform op is linear). Its analytic output equals the hardcoded
    /// velocity-attenuation curve this port already applies elsewhere (`Voice.swift:141`) — see
    /// `ModulatorTransformTests.default1OutputMatchesHardcodedCurve`.
    ///
    /// Default #2 (§8.4.2, key number to initial filter cutoff) is deferred (design spec §4) —
    /// `noteOn` deliberately holds only default #1 this release.
    ///
    /// Built via `Modulator.read`, wire-encoding the exact 10-byte `pmod`/`imod` record
    /// (`ModulatorTransformTests.default1OutputMatchesHardcodedCurve`'s `src: 0x0502, dest: 48,
    /// amount: 960, amtSrc: 0x0, transform: 0`) rather than a memberwise initializer: `Modulator`
    /// exposes none outside `Modulator.swift` (its private validity flags make the synthesized
    /// one private to that file).
    static let noteOn: [Modulator] = {
        let record = Data([0x02, 0x05, 0x30, 0x00, 0xC0, 0x03, 0x00, 0x00, 0x00, 0x00])
        // Fixed, hand-verified bytes decoded through the already-tested `Modulator.read` — never
        // throws in practice, so a force-try keeps this a simple stored constant.
        // swiftlint:disable:next force_try
        return [try! Modulator.read(from: BinaryReader(data: record))]
    }()
}
