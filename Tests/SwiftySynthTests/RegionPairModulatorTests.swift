import Testing
@testable import SwiftySynth

/// Builds a minimal, valid `RegionPair` for exercising `RegionPair`'s modulator-combination members
/// in isolation, following the same direct-construction shape `RegionPairTests.swift`'s `makeParts`
/// uses for the generator-combination tests: a single placeholder `SampleHeader`/`Instrument` just
/// deep enough to satisfy `InstrumentRegion`/`PresetRegion`'s sample-ID / instrument-ID resolution,
/// with no generators of interest — only the `modulators:` lists this suite cares about.
private func makeRegionPair(
    instrumentModulators: [Modulator] = [],
    presetModulators: [Modulator] = []
) throws -> RegionPair {
    let header = SampleHeader(
        name: "S", start: 10, end: 1000, startLoop: 100, endLoop: 900,
        sampleRate: 44_100, originalPitch: 60, pitchCorrection: 0,
        link: 0, sampleType: 1)
    let instrumentRegion = try InstrumentRegion(
        global: [], local: [Generator(type: .sampleID, value: 0)], samples: [header],
        modulators: instrumentModulators)
    let instrument = try Instrument(
        name: "I", zones: [Zone(generators: [Generator(type: .sampleID, value: 0)])], samples: [header])
    let presetRegion = try PresetRegion(
        global: [], local: [Generator(type: .instrument, value: 0)], instruments: [instrument],
        modulators: presetModulators)
    return RegionPair(preset: presetRegion, instrument: instrumentRegion)
}

struct RegionPairModulatorTests {
    /// SF2 default modulator #1 (velocity -> initialAttenuation, concave, maxToMin): a low velocity
    /// should attenuate MORE than a high velocity, per the concave/maxToMin shape.
    @Test func modulatorSumForAttenuationAttenuatesMoreAtLowVelocity() throws {
        let pair = try makeRegionPair(
            instrumentModulators: [makeVelocityToAttenuationModulator(amount: 700)])

        let sum80 = pair.modulatorSum(destination: .initialAttenuation, velocity: 80, key: 60)
        let sum49 = pair.modulatorSum(destination: .initialAttenuation, velocity: 49, key: 60)

        #expect(sum49 > sum80, "concave maxToMin attenuates more at low velocity")
    }

    /// Task-7 carry-forward: `instrument.modulators` and `preset.modulators` each carry a
    /// velocity->initialAttenuation entry that is 3-field-identical (same source, destination,
    /// amount-source) to the other but differs only in `transform`. `RegionPair.resolvedModulators`
    /// must be a plain concatenation of the two already-resolved lists — re-running
    /// `ModulatorResolver`'s dedup/supersession machinery on top would incorrectly collapse these
    /// (its identity check is transform-blind), dropping a legitimate entry. Both must survive and
    /// both must contribute to `modulatorSum`.
    @Test func resolvedModulatorsIsPlainConcatNotReResolved() throws {
        let instrumentModulator = makeModulator(src: 0x0502, dest: 48, amount: 600, amtSrc: 0, transform: 0)
        let presetModulator = makeModulator(src: 0x0502, dest: 48, amount: 800, amtSrc: 0, transform: 2)

        // Sanity-check the fixture actually hits the trap this test is pinning: 3-field-identical,
        // 4-field-distinct (transform differs).
        #expect(instrumentModulator.isIdentical3(to: presetModulator))
        #expect(!instrumentModulator.isIdentical4(to: presetModulator))

        let pair = try makeRegionPair(
            instrumentModulators: [instrumentModulator], presetModulators: [presetModulator])

        #expect(pair.resolvedModulators.count == 2)
        #expect(Set(pair.resolvedModulators.map(\.amount)) == [600, 800])

        let velocity = 80
        let key = 60
        let expectedSum = instrumentModulator.output(velocity: velocity, key: key)
            + presetModulator.output(velocity: velocity, key: key)
        let actualSum = pair.modulatorSum(destination: .initialAttenuation, velocity: velocity, key: key)

        expectClose(actualSum, expectedSum)
    }
}
