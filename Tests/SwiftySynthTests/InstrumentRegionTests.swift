import Testing
@testable import SwiftySynth

private func makeHeader(
    start: Int32 = 0, end: Int32 = 1000, startLoop: Int32 = 100, endLoop: Int32 = 900,
    originalPitch: Int32 = 60, pitchCorrection: Int32 = 0
) -> SampleHeader {
    SampleHeader(
        name: "S", start: start, end: end, startLoop: startLoop, endLoop: endLoop,
        sampleRate: 44_100, originalPitch: originalPitch, pitchCorrection: pitchCorrection,
        link: 0, sampleType: 1)
}

private func gen(_ type: GeneratorType, _ value: Int16) -> Generator {
    Generator(type: type, value: UInt16(bitPattern: value))
}

private func range(_ type: GeneratorType, low: UInt8, high: UInt8) -> Generator {
    Generator(type: type, value: UInt16(low) | (UInt16(high) << 8))
}

struct InstrumentRegionTests {
    @Test func defaultsMatchSF2Spec() throws {
        let region = try InstrumentRegion(global: [], local: [gen(.sampleID, 0)], samples: [makeHeader()])
        // The load-bearing default: initialFilterFc 13500 cents ≈ 19912.6 Hz — BELOW the
        // filter's ~22006 Hz bypass threshold, so the filter runs at SF2 defaults.
        expectClose(region.initialFilterCutoffFrequency, SoundFontMath.centsToHertz(13500))
        expectClose(region.delayVolumeEnvelope, SoundFontMath.timecentsToSeconds(-12000))
        expectClose(region.attackVolumeEnvelope, SoundFontMath.timecentsToSeconds(-12000))
        expectClose(region.delayModulationLfo, SoundFontMath.timecentsToSeconds(-12000))
        #expect(region.scaleTuning == 100)
        #expect(region.keyRangeStart == 0)
        #expect(region.keyRangeEnd == 127)
        #expect(region.velocityRangeStart == 0)
        #expect(region.velocityRangeEnd == 127)
        #expect(region.rootKey == 60)     // overridingRootKey default -1 → sample.originalPitch
        expectClose(region.pan, 0)
        expectClose(region.initialAttenuation, 0)
        #expect(region.sampleModes == .noLoop)
        #expect(region.exclusiveClass == 0)
    }

    @Test func addressOffsetsUseCoarse32768() throws {
        let region = try InstrumentRegion(
            global: [],
            local: [gen(.startAddressCoarseOffset, 2), gen(.startAddressOffset, 10), gen(.sampleID, 0)],
            samples: [makeHeader(start: 5)])
        #expect(region.startAddressOffset == 2 * 32_768 + 10)
        #expect(region.sampleStart == 5 + 2 * 32_768 + 10)
    }

    @Test func globalZoneSuppliesDefaultsAndLocalOverrides() throws {
        let zones = [
            Zone(generators: [gen(.initialAttenuation, 100), gen(.pan, -500)]), // global: last gen ≠ sampleID
            Zone(generators: [gen(.initialAttenuation, 250), gen(.sampleID, 0)]),
        ]
        let instrument = try Instrument(name: "I", zones: zones, samples: [makeHeader()])
        #expect(instrument.regions.count == 1)
        expectClose(instrument.regions[0].initialAttenuation, 25.0) // local override: 0.1 × 250
        expectClose(instrument.regions[0].pan, -50.0)               // global fills the gap: 0.1 × (-500)
    }

    @Test func firstZoneEndingInSampleIDIsNotGlobal() throws {
        let zones = [
            Zone(generators: [gen(.sampleID, 0)]),
            Zone(generators: [gen(.sampleID, 0)]),
        ]
        let instrument = try Instrument(name: "I", zones: zones, samples: [makeHeader()])
        #expect(instrument.regions.count == 2)
    }

    @Test func keyAndVelocityContainment() throws {
        let region = try InstrumentRegion(
            global: [],
            local: [range(.keyRange, low: 40, high: 60), range(.velocityRange, low: 20, high: 80), gen(.sampleID, 0)],
            samples: [makeHeader()])
        #expect(region.contains(key: 40, velocity: 20))
        #expect(region.contains(key: 60, velocity: 80))
        #expect(!region.contains(key: 39, velocity: 50))
        #expect(!region.contains(key: 61, velocity: 50))
        #expect(!region.contains(key: 50, velocity: 81))
    }

    @Test func sampleModesWireTwoMapsToNoLoop() throws {
        func region(mode: Int16) throws -> InstrumentRegion {
            try InstrumentRegion(global: [], local: [gen(.sampleModes, mode), gen(.sampleID, 0)], samples: [makeHeader()])
        }
        #expect(try region(mode: 1).sampleModes == .continuous)
        #expect(try region(mode: 2).sampleModes == .noLoop)  // reserved wire value → noLoop
        #expect(try region(mode: 3).sampleModes == .loopUntilNoteOff)
    }

    @Test func overridingRootKeyWins() throws {
        let region = try InstrumentRegion(
            global: [], local: [gen(.overridingRootKey, 72), gen(.sampleID, 0)], samples: [makeHeader()])
        #expect(region.rootKey == 72)
    }

    @Test func fineTuneAddsSamplePitchCorrection() throws {
        let region = try InstrumentRegion(
            global: [], local: [gen(.fineTune, 7), gen(.sampleID, 0)],
            samples: [makeHeader(pitchCorrection: -5)])
        #expect(region.fineTune == 2)
    }

    @Test func invalidSampleIDThrows() {
        #expect(throws: SwiftySynthError.self) {
            _ = try InstrumentRegion(global: [], local: [gen(.sampleID, 9)], samples: [makeHeader()])
        }
    }
}
