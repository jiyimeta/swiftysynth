import Testing
@testable import SwiftySynth

/// `enableModulators` is opt-in and defaults to `false`; it mirrors the
/// `enableReverbAndChorus` `let` + defaulted-init-parameter shape covered by
/// `SynthesizerSettingsTests`. At this stage the flag is plumbed but inert —
/// no behavior is gated on it yet.
struct ModulatorSettingsTests {
    @Test func defaultsToFalse() throws {
        let settings = try SynthesizerSettings(sampleRate: 44_100)
        #expect(settings.enableModulators == false)
    }

    @Test func canEnable() throws {
        let settings = try SynthesizerSettings(sampleRate: 44_100, enableModulators: true)
        #expect(settings.enableModulators == true)
    }
}
