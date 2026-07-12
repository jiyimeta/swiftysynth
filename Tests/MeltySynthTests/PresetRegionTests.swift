import Testing
@testable import MeltySynth

private func gen(_ type: GeneratorType, _ value: Int16) -> Generator {
    Generator(type: type, value: UInt16(bitPattern: value))
}

private func makeInstrument() throws -> Instrument {
    let header = SampleHeader(
        name: "S", start: 0, end: 1000, startLoop: 100, endLoop: 900,
        sampleRate: 44_100, originalPitch: 60, pitchCorrection: 0, link: 0, sampleType: 1)
    return try Instrument(
        name: "I",
        zones: [Zone(generators: [gen(.sampleID, 0)])],
        samples: [header])
}

struct PresetRegionTests {
    @Test func defaultsAreNeutralOffsets() throws {
        let region = try PresetRegion(global: [], local: [gen(.instrument, 0)], instruments: [try makeInstrument()])
        expectClose(region.initialFilterCutoffFrequency, 1)   // factor 2^0
        expectClose(region.delayVolumeEnvelope, 1)
        expectClose(region.initialAttenuation, 0)             // additive dB offset
        expectClose(region.pan, 0)
        #expect(region.fineTune == 0)                         // no pitchCorrection on the preset side
        #expect(region.keyRangeStart == 0)
        #expect(region.keyRangeEnd == 127)
    }

    @Test func linksInstrumentByGeneratorValue() throws {
        let instrument = try makeInstrument()
        let region = try PresetRegion(global: [], local: [gen(.instrument, 0)], instruments: [instrument])
        #expect(region.instrument === instrument)
    }

    @Test func globalZoneRuleUsesInstrumentTerminator() throws {
        let instrument = try makeInstrument()
        // First zone lacks a terminal `instrument` generator → global.
        let withGlobal = try Preset(
            name: "P", patchNumber: 0, bankNumber: 0,
            zones: [
                Zone(generators: [gen(.initialAttenuation, 40)]),
                Zone(generators: [gen(.instrument, 0)]),
                Zone(generators: [gen(.initialAttenuation, 100), gen(.instrument, 0)]),
            ],
            instruments: [instrument])
        #expect(withGlobal.regions.count == 2)
        expectClose(withGlobal.regions[0].initialAttenuation, 4.0)   // inherited from global
        expectClose(withGlobal.regions[1].initialAttenuation, 10.0)  // local override

        // First zone ends in `instrument` → no global zone.
        let withoutGlobal = try Preset(
            name: "P", patchNumber: 0, bankNumber: 0,
            zones: [
                Zone(generators: [gen(.instrument, 0)]),
                Zone(generators: [gen(.instrument, 0)]),
            ],
            instruments: [instrument])
        #expect(withoutGlobal.regions.count == 2)
    }

    @Test func floatGettersAreRelativeFactors() throws {
        let region = try PresetRegion(
            global: [],
            local: [gen(.initialFilterCutoffFrequency, 1200), gen(.decayVolumeEnvelope, -1200), gen(.instrument, 0)],
            instruments: [try makeInstrument()])
        expectClose(region.initialFilterCutoffFrequency, 2)   // 2^(1200/1200) — a factor, not Hz
        expectClose(region.decayVolumeEnvelope, 0.5)
    }

    @Test func invalidInstrumentIndexThrows() throws {
        let instrument = try makeInstrument()
        #expect(throws: MeltySynthError.self) {
            _ = try PresetRegion(global: [], local: [gen(.instrument, 5)], instruments: [instrument])
        }
    }
}
