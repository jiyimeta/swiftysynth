import Foundation

/// Identifies a SoundFont generator parameter.
///
/// Ported from `GeneratorType.cs` (MeltySynth, MIT License — see NOTICE).
/// All 61 SF2-spec generator types (raw values 0...60) are transcribed.
enum GeneratorType: UInt16 {
    case startAddressOffset = 0
    case endAddressOffset = 1
    case startLoopAddressOffset = 2
    case endLoopAddressOffset = 3
    case startAddressCoarseOffset = 4
    case modulationLfoToPitch = 5
    case vibratoLfoToPitch = 6
    case modulationEnvelopeToPitch = 7
    case initialFilterCutoffFrequency = 8
    case initialFilterQ = 9
    case modulationLfoToFilterCutoffFrequency = 10
    case modulationEnvelopeToFilterCutoffFrequency = 11
    case endAddressCoarseOffset = 12
    case modulationLfoToVolume = 13
    case unused1 = 14
    case chorusEffectsSend = 15
    case reverbEffectsSend = 16
    case pan = 17
    case unused2 = 18
    case unused3 = 19
    case unused4 = 20
    case delayModulationLfo = 21
    case frequencyModulationLfo = 22
    case delayVibratoLfo = 23
    case frequencyVibratoLfo = 24
    case delayModulationEnvelope = 25
    case attackModulationEnvelope = 26
    case holdModulationEnvelope = 27
    case decayModulationEnvelope = 28
    case sustainModulationEnvelope = 29
    case releaseModulationEnvelope = 30
    case keyNumberToModulationEnvelopeHold = 31
    case keyNumberToModulationEnvelopeDecay = 32
    case delayVolumeEnvelope = 33
    case attackVolumeEnvelope = 34
    case holdVolumeEnvelope = 35
    case decayVolumeEnvelope = 36
    case sustainVolumeEnvelope = 37
    case releaseVolumeEnvelope = 38
    case keyNumberToVolumeEnvelopeHold = 39
    case keyNumberToVolumeEnvelopeDecay = 40
    case instrument = 41
    case reserved1 = 42
    case keyRange = 43
    case velocityRange = 44
    case startLoopAddressCoarseOffset = 45
    case keyNumber = 46
    case velocity = 47
    case initialAttenuation = 48
    case reserved2 = 49
    case endLoopAddressCoarseOffset = 50
    case coarseTune = 51
    case fineTune = 52
    case sampleID = 53
    case sampleModes = 54
    case reserved3 = 55
    case scaleTuning = 56
    case exclusiveClass = 57
    case overridingRootKey = 58
    case unused5 = 59
    case unusedEnd = 60

    static let count = 61
}

/// A single SoundFont generator record (parameter type + raw wire value).
///
/// Ported from `Generator.cs` (MeltySynth, MIT License — see NOTICE).
/// `value` is kept as the raw `UInt16` read off the wire — C# stores the same
/// bits and reinterprets them as `(short)Value` later, at `gs[]` application
/// time; the Swift port defers that reinterpretation the same way, via
/// `Int16(bitPattern:)` at the call site.
struct Generator {
    let type: GeneratorType
    let value: UInt16

    init(type: GeneratorType, value: UInt16) {
        self.type = type
        self.value = value
    }

    init(reader: BinaryReader) throws {
        let rawType = try reader.readUInt16()
        guard let type = GeneratorType(rawValue: rawType) else {
            throw MeltySynthError.invalidSoundFont("unknown generator type: \(rawType)")
        }
        self.type = type
        self.value = try reader.readUInt16()
    }

    /// Reads a `pgen`/`igen` sub-chunk. Each record is 4 bytes (type + value);
    /// the final record is a terminator and is read but dropped.
    static func readFromChunk(reader: BinaryReader, size: Int) throws -> [Generator] {
        guard size % 4 == 0 else {
            throw MeltySynthError.invalidSoundFont("The generator list is invalid.")
        }

        var generators: [Generator] = []
        generators.reserveCapacity(size / 4 - 1)

        for _ in 0..<(size / 4 - 1) {
            generators.append(try Generator(reader: reader))
        }

        // The last one is the terminator.
        _ = try Generator(reader: reader)

        return generators
    }
}
