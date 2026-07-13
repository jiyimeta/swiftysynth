import Foundation

struct OracleDump: Decodable {
    struct Version: Decodable { let major: Int; let minor: Int }
    struct Info: Decodable {
        let targetSoundEngine: String
        let bankName: String
        let romName: String
        let creationDate: String
        let author: String
        let targetProduct: String
        let copyright: String
        let comments: String
        let tools: String
    }
    struct Counts: Decodable { let presets: Int; let instruments: Int; let sampleHeaders: Int }
    struct Smpl: Decodable { let sampleCount: Int; let sha256: String }
    struct PresetSummary: Decodable { let bank: Int; let patch: Int; let name: String }
    struct SampleHeaderRecord: Decodable {
        let name: String
        let start: Int
        let end: Int
        let startLoop: Int
        let endLoop: Int
        let sampleRate: Int
        let originalPitch: Int
        let pitchCorrection: Int
        let link: Int
        let sampleType: Int
    }
    struct PresetRegionRecord: Decodable {
        let instrumentIndex: Int
        let instrumentName: String
        let keyRangeStart: Int
        let keyRangeEnd: Int
        let velocityRangeStart: Int
        let velocityRangeEnd: Int
        let modulationLfoToPitch: Int
        let vibratoLfoToPitch: Int
        let modulationEnvelopeToPitch: Int
        let modulationLfoToFilterCutoffFrequency: Int
        let modulationEnvelopeToFilterCutoffFrequency: Int
        let keyNumberToModulationEnvelopeHold: Int
        let keyNumberToModulationEnvelopeDecay: Int
        let keyNumberToVolumeEnvelopeHold: Int
        let keyNumberToVolumeEnvelopeDecay: Int
        let coarseTune: Int
        let fineTune: Int
        let scaleTuning: Int
        let initialFilterCutoffFrequency: Double
        let initialFilterQ: Double
        let modulationLfoToVolume: Double
        let chorusEffectsSend: Double
        let reverbEffectsSend: Double
        let pan: Double
        let delayModulationLfo: Double
        let frequencyModulationLfo: Double
        let delayVibratoLfo: Double
        let frequencyVibratoLfo: Double
        let delayModulationEnvelope: Double
        let attackModulationEnvelope: Double
        let holdModulationEnvelope: Double
        let decayModulationEnvelope: Double
        let sustainModulationEnvelope: Double
        let releaseModulationEnvelope: Double
        let delayVolumeEnvelope: Double
        let attackVolumeEnvelope: Double
        let holdVolumeEnvelope: Double
        let decayVolumeEnvelope: Double
        let sustainVolumeEnvelope: Double
        let releaseVolumeEnvelope: Double
        let initialAttenuation: Double
    }
    struct InstrumentRegionRecord: Decodable {
        let sampleIndex: Int
        let sampleName: String
        let sampleStart: Int
        let sampleEnd: Int
        let sampleStartLoop: Int
        let sampleEndLoop: Int
        let startAddressOffset: Int
        let endAddressOffset: Int
        let startLoopAddressOffset: Int
        let endLoopAddressOffset: Int
        let sampleModes: Int
        let rootKey: Int
        let exclusiveClass: Int
        let keyRangeStart: Int
        let keyRangeEnd: Int
        let velocityRangeStart: Int
        let velocityRangeEnd: Int
        let modulationLfoToPitch: Int
        let vibratoLfoToPitch: Int
        let modulationEnvelopeToPitch: Int
        let modulationLfoToFilterCutoffFrequency: Int
        let modulationEnvelopeToFilterCutoffFrequency: Int
        let keyNumberToModulationEnvelopeHold: Int
        let keyNumberToModulationEnvelopeDecay: Int
        let keyNumberToVolumeEnvelopeHold: Int
        let keyNumberToVolumeEnvelopeDecay: Int
        let coarseTune: Int
        let fineTune: Int
        let scaleTuning: Int
        let initialFilterCutoffFrequency: Double
        let initialFilterQ: Double
        let modulationLfoToVolume: Double
        let chorusEffectsSend: Double
        let reverbEffectsSend: Double
        let pan: Double
        let delayModulationLfo: Double
        let frequencyModulationLfo: Double
        let delayVibratoLfo: Double
        let frequencyVibratoLfo: Double
        let delayModulationEnvelope: Double
        let attackModulationEnvelope: Double
        let holdModulationEnvelope: Double
        let decayModulationEnvelope: Double
        let sustainModulationEnvelope: Double
        let releaseModulationEnvelope: Double
        let delayVolumeEnvelope: Double
        let attackVolumeEnvelope: Double
        let holdVolumeEnvelope: Double
        let decayVolumeEnvelope: Double
        let sustainVolumeEnvelope: Double
        let releaseVolumeEnvelope: Double
        let initialAttenuation: Double
    }
    struct InstrumentRecord: Decodable {
        let index: Int
        let name: String
        let regions: [InstrumentRegionRecord]
    }
    struct PairRecord: Decodable {
        let presetRegionIndex: Int
        let instrumentRegionIndex: Int
        let sampleStart: Int
        let sampleEnd: Int
        let sampleStartLoop: Int
        let sampleEndLoop: Int
        let sampleModes: Int
        let rootKey: Int
        let exclusiveClass: Int
        let modulationLfoToPitch: Int
        let vibratoLfoToPitch: Int
        let modulationEnvelopeToPitch: Int
        let modulationLfoToFilterCutoffFrequency: Int
        let modulationEnvelopeToFilterCutoffFrequency: Int
        let keyNumberToModulationEnvelopeHold: Int
        let keyNumberToModulationEnvelopeDecay: Int
        let keyNumberToVolumeEnvelopeHold: Int
        let keyNumberToVolumeEnvelopeDecay: Int
        let coarseTune: Int
        let fineTune: Int
        let scaleTuning: Int
        let modulationLfoToVolume: Double
        let chorusEffectsSend: Double
        let reverbEffectsSend: Double
        let pan: Double
        let initialFilterQ: Double
        let sustainModulationEnvelope: Double
        let sustainVolumeEnvelope: Double
        let initialAttenuation: Double
        let initialFilterCutoffFrequency: Double
        let delayModulationLfo: Double
        let frequencyModulationLfo: Double
        let delayVibratoLfo: Double
        let frequencyVibratoLfo: Double
        let delayModulationEnvelope: Double
        let attackModulationEnvelope: Double
        let holdModulationEnvelope: Double
        let decayModulationEnvelope: Double
        let releaseModulationEnvelope: Double
        let delayVolumeEnvelope: Double
        let attackVolumeEnvelope: Double
        let holdVolumeEnvelope: Double
        let decayVolumeEnvelope: Double
        let releaseVolumeEnvelope: Double
    }
    struct Bank0Preset0: Decodable {
        let name: String
        let library: Int
        let genre: Int
        let morphology: Int
        let presetRegions: [PresetRegionRecord]
        let instruments: [InstrumentRecord]
        let pairs: [PairRecord]
    }
    let version: Version
    let romVersion: Version
    let info: Info
    let counts: Counts
    let smpl: Smpl
    let presets: [PresetSummary]
    let sampleHeaders: [SampleHeaderRecord]
    let bank0Preset0: Bank0Preset0
}
