import Testing
@testable import SwiftySynth

private func gen(_ type: GeneratorType, _ value: Int16) -> Generator {
    Generator(type: type, value: UInt16(bitPattern: value))
}

private func makeParts(
    instrumentGens: [Generator],
    presetGens: [Generator],
    pitchCorrection: Int32 = 0
) throws -> RegionPair {
    let header = SampleHeader(
        name: "S", start: 10, end: 1000, startLoop: 100, endLoop: 900,
        sampleRate: 44_100, originalPitch: 60, pitchCorrection: pitchCorrection,
        link: 0, sampleType: 1)
    let instrumentRegion = try InstrumentRegion(
        global: [], local: instrumentGens + [gen(.sampleID, 0)], samples: [header])
    let instrument = try Instrument(
        name: "I", zones: [Zone(generators: instrumentGens + [gen(.sampleID, 0)])], samples: [header])
    let presetRegion = try PresetRegion(
        global: [], local: presetGens + [gen(.instrument, 0)], instruments: [instrument])
    return RegionPair(preset: presetRegion, instrument: instrumentRegion)
}

struct RegionPairTests {
    @Test func presetOffsetsAddToInstrumentValues() throws {
        let pair = try makeParts(
            instrumentGens: [gen(.initialAttenuation, 100), gen(.initialFilterCutoffFrequency, 6000)],
            presetGens: [gen(.initialAttenuation, 50), gen(.initialFilterCutoffFrequency, 1200)])
        expectClose(pair.initialAttenuation, 15.0)                                  // 0.1 × (100 + 50)
        expectClose(pair.initialFilterCutoffFrequency, SoundFontMath.centsToHertz(7200))
    }

    @Test func envelopeTimesSumInTimecents() throws {
        let pair = try makeParts(
            instrumentGens: [gen(.decayVolumeEnvelope, 1200)],   // 2 s
            presetGens: [gen(.decayVolumeEnvelope, -1200)])      // × 0.5
        expectClose(pair.decayVolumeEnvelope, SoundFontMath.timecentsToSeconds(0))  // 1 s
    }

    @Test func sampleParametersComeFromInstrumentOnly() throws {
        // The preset side maliciously carries sample-scope generators — canonical
        // RegionPair must ignore them. Getting this wrong is "plausibly wrong audio".
        let pair = try makeParts(
            instrumentGens: [gen(.startAddressOffset, 3), gen(.sampleModes, 1)],
            presetGens: [gen(.startAddressOffset, 999), gen(.sampleModes, 3),
                         gen(.overridingRootKey, 10), gen(.exclusiveClass, 7)])
        #expect(pair.sampleStart == 10 + 3)         // preset 999 ignored
        #expect(pair.sampleModes == .continuous)    // preset 3 ignored
        #expect(pair.rootKey == 60)                 // preset override ignored
        #expect(pair.exclusiveClass == 0)           // preset 7 ignored
    }

    @Test func fineTuneCombinesBothSidesPlusPitchCorrection() throws {
        let pair = try makeParts(
            instrumentGens: [gen(.fineTune, 7)],
            presetGens: [gen(.fineTune, 3)],
            pitchCorrection: -5)
        #expect(pair.fineTune == 5)   // 7 + 3 + (−5), pitch correction counted exactly once
    }

    @Test func intModulationRoutingsAdd() throws {
        let pair = try makeParts(
            instrumentGens: [gen(.modulationLfoToPitch, 30), gen(.scaleTuning, 100)],
            presetGens: [gen(.modulationLfoToPitch, -10), gen(.scaleTuning, -20)])
        #expect(pair.modulationLfoToPitch == 20)
        #expect(pair.scaleTuning == 80)
    }
}
