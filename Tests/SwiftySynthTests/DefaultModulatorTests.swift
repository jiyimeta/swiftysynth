import Testing
@testable import SwiftySynth

/// Hermetic. `DefaultModulators.noteOn` — the SF2 §8.4.1 default modulator #1 (velocity to
/// initial attenuation) that ships pre-populated whenever a preset/instrument zone has no
/// explicit modulator list (SF2 §7.4/§8.4). Default #2 (§8.4.2, key number to initial filter
/// cutoff) is deferred (design spec §4) and is deliberately absent from this set.
struct DefaultModulatorTests {
    @Test func defaultSetIsExactlyDefault1() {
        let d = DefaultModulators.noteOn
        #expect(d.count == 1)
        let m = d[0]
        #expect(m.source.controller == .velocity)
        #expect(m.source.curve == .concave)
        #expect(m.source.direction == .maxToMin)
        #expect(m.destination == .initialAttenuation)
        #expect(m.amount == 960)
        #expect(m.isNoteOn)
    }
}
