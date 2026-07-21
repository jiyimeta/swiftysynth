import Foundation
import Testing
@testable import SwiftySynth

/// `Zone.modulators` — the per-zone modulator slice, cut from the parsed `pmod`/`imod` array using
/// `ZoneInfo.modulatorIndex`/`modulatorCount` (full-port spec §2). Unlike the generator-range guard
/// (`Zone.init(info:generators:)`, which throws on a corrupt bag range), the modulator slice guard
/// is deliberately non-throwing: a font with a corrupt `wModNdx` loads fine today because nothing
/// consumes those indices, and this feature must not turn that into a load failure.
struct ZoneModulatorSliceTests {
    @Test func testValidSlice() throws {
        let infos = [
            ZoneInfo(generatorIndex: 0, modulatorIndex: 0, generatorCount: 0, modulatorCount: 2),
            ZoneInfo(generatorIndex: 0, modulatorIndex: 2, generatorCount: 0, modulatorCount: 0),
        ]
        let zones = try Zone.create(
            infos: infos,
            generators: [],
            modulators: [
                makeVelocityToAttenuationModulator(amount: 700),
                makeVelocityToAttenuationModulator(amount: 800),
            ]
        )
        #expect(zones.count == 1)
        #expect(zones[0].modulators.count == 2)
    }

    @Test func testCorruptModRangeYieldsEmptyNotThrow() throws {
        // modulatorCount 5 but only 1 modulator present -> that zone's modulators empty, no throw.
        let infos = [
            ZoneInfo(generatorIndex: 0, modulatorIndex: 0, generatorCount: 0, modulatorCount: 5),
            ZoneInfo(generatorIndex: 0, modulatorIndex: 5, generatorCount: 0, modulatorCount: 0),
        ]
        let zones = try Zone.create(
            infos: infos,
            generators: [],
            modulators: [makeVelocityToAttenuationModulator(amount: 700)]
        )
        #expect(zones.count == 1)
        #expect(zones[0].modulators.count == 0, "corrupt wModNdx must yield empty, not throw")
    }
}
