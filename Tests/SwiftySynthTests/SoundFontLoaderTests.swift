import Foundation
import Testing
@testable import SwiftySynth

/// Mismatch collector: exact for ints/strings, ≤1e-6 relative for derived floats (G1 bar).
private struct Diff {
    var failures: [String] = []
    mutating func eq(_ a: Int, _ b: Int, _ label: @autoclosure () -> String) {
        if a != b { failures.append("\(label()): swift=\(a) oracle=\(b)") }
    }
    mutating func eq(_ a: String, _ b: String, _ label: @autoclosure () -> String) {
        if a != b { failures.append("\(label()): swift=\"\(a)\" oracle=\"\(b)\"") }
    }
    mutating func close(_ a: Float, _ b: Double, _ label: @autoclosure () -> String) {
        let x = Double(a)
        let scale = max(abs(x), abs(b))
        if x != b && abs(x - b) > 1e-6 * scale {
            failures.append("\(label()): swift=\(x) oracle=\(b) relErr=\(abs(x - b) / max(scale, .leastNormalMagnitude))")
        }
    }
}

@Suite(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
struct SoundFontLoaderTests {
    /// **G1** — Swift-loaded font structurally equals the oracle's dump-font JSON.
    @Test func structuralEquivalence() throws {
        let dumpURL = try #require(Fixtures.url("generaluser-gs-dump", "json"))
        let dump = try JSONDecoder().decode(OracleDump.self, from: Data(contentsOf: dumpURL))
        let font = try SoundFont(url: FixtureSF2.url)
        var d = Diff()

        // ifil version + INFO strings — exact.
        d.eq(Int(font.info.version.major), dump.version.major, "version.major")
        d.eq(Int(font.info.version.minor), dump.version.minor, "version.minor")
        d.eq(Int(font.info.romVersion.major), dump.romVersion.major, "romVersion.major")
        d.eq(Int(font.info.romVersion.minor), dump.romVersion.minor, "romVersion.minor")
        d.eq(font.info.targetSoundEngine, dump.info.targetSoundEngine, "info.targetSoundEngine")
        d.eq(font.info.bankName, dump.info.bankName, "info.bankName")
        d.eq(font.info.romName, dump.info.romName, "info.romName")
        d.eq(font.info.creationDate, dump.info.creationDate, "info.creationDate")
        d.eq(font.info.author, dump.info.author, "info.author")
        d.eq(font.info.targetProduct, dump.info.targetProduct, "info.targetProduct")
        d.eq(font.info.copyright, dump.info.copyright, "info.copyright")
        d.eq(font.info.comments, dump.info.comments, "info.comments")
        d.eq(font.info.tools, dump.info.tools, "info.tools")

        // Record counts — exact.
        d.eq(font.presets.count, dump.counts.presets, "counts.presets")
        d.eq(font.instruments.count, dump.counts.instruments, "counts.instruments")
        d.eq(font.sampleHeaders.count, dump.counts.sampleHeaders, "counts.sampleHeaders")

        // smpl — length + SHA-256.
        d.eq(font.waveData.count, dump.smpl.sampleCount, "smpl.sampleCount")
        d.eq(smplSHA256(font.waveData), dump.smpl.sha256, "smpl.sha256")

        // Full preset directory — parse order, bank/patch/name exact.
        if font.presets.count == dump.presets.count {
            for (i, p) in font.presets.enumerated() {
                d.eq(p.bankNumber, dump.presets[i].bank, "presets[\(i)].bank")
                d.eq(p.patchNumber, dump.presets[i].patch, "presets[\(i)].patch")
                d.eq(p.name, dump.presets[i].name, "presets[\(i)].name")
            }
        }

        // All sample headers — exact.
        if font.sampleHeaders.count == dump.sampleHeaders.count {
            for (i, h) in font.sampleHeaders.enumerated() {
                let o = dump.sampleHeaders[i]
                d.eq(h.name, o.name, "shdr[\(i)].name")
                d.eq(Int(h.start), o.start, "shdr[\(i)].start")
                d.eq(Int(h.end), o.end, "shdr[\(i)].end")
                d.eq(Int(h.startLoop), o.startLoop, "shdr[\(i)].startLoop")
                d.eq(Int(h.endLoop), o.endLoop, "shdr[\(i)].endLoop")
                d.eq(Int(h.sampleRate), o.sampleRate, "shdr[\(i)].sampleRate")
                d.eq(Int(h.originalPitch), o.originalPitch, "shdr[\(i)].originalPitch")
                d.eq(Int(h.pitchCorrection), o.pitchCorrection, "shdr[\(i)].pitchCorrection")
                d.eq(Int(h.link), o.link, "shdr[\(i)].link")
                d.eq(Int(h.sampleType), o.sampleType, "shdr[\(i)].sampleType")
            }
        }

        // Bank 0 / preset 0 derived-value region tree.
        let preset = try #require(font.presets.first { $0.bankNumber == 0 && $0.patchNumber == 0 })
        d.eq(preset.name, dump.bank0Preset0.name, "preset0.name")
        d.eq(preset.library, dump.bank0Preset0.library, "preset0.library")
        d.eq(preset.genre, dump.bank0Preset0.genre, "preset0.genre")
        d.eq(preset.morphology, dump.bank0Preset0.morphology, "preset0.morphology")
        d.eq(preset.regions.count, dump.bank0Preset0.presetRegions.count, "preset0.regionCount")

        if preset.regions.count == dump.bank0Preset0.presetRegions.count {
            for (i, r) in preset.regions.enumerated() {
                comparePresetRegion(r, dump.bank0Preset0.presetRegions[i], font: font, label: "presetRegion[\(i)]", into: &d)
            }
        }

        for record in dump.bank0Preset0.instruments {
            guard record.index < font.instruments.count else {
                d.failures.append("instrument index \(record.index) out of range")
                continue
            }
            let instrument = font.instruments[record.index]
            d.eq(instrument.name, record.name, "instrument[\(record.index)].name")
            d.eq(instrument.regions.count, record.regions.count, "instrument[\(record.index)].regionCount")
            if instrument.regions.count == record.regions.count {
                for (j, ir) in instrument.regions.enumerated() {
                    compareInstrumentRegion(ir, record.regions[j], font: font, label: "instrument[\(record.index)].region[\(j)]", into: &d)
                }
            }
        }

        // RegionPair tree — same (presetRegion × instrumentRegion) enumeration as the dumper.
        var pairIndex = 0
        for (pi, pr) in preset.regions.enumerated() {
            for (ii, ir) in pr.instrument.regions.enumerated() {
                guard pairIndex < dump.bank0Preset0.pairs.count else { break }
                let o = dump.bank0Preset0.pairs[pairIndex]
                d.eq(pi, o.presetRegionIndex, "pair[\(pairIndex)].presetRegionIndex")
                d.eq(ii, o.instrumentRegionIndex, "pair[\(pairIndex)].instrumentRegionIndex")
                comparePair(RegionPair(preset: pr, instrument: ir), o, label: "pair[\(pairIndex)]", into: &d)
                pairIndex += 1
            }
        }
        d.eq(pairIndex, dump.bank0Preset0.pairs.count, "pairs.count")

        print("G1: compared \(dump.sampleHeaders.count) sample headers, \(dump.presets.count) presets, \(dump.bank0Preset0.pairs.count) region pairs — \(d.failures.count) mismatches")
        #expect(
            d.failures.isEmpty,
            "\(d.failures.count) mismatches; first 25:\n\(d.failures.prefix(25).joined(separator: "\n"))")
    }

    private func comparePresetRegion(
        _ r: PresetRegion, _ o: OracleDump.PresetRegionRecord, font: SoundFont,
        label: String, into d: inout Diff
    ) {
        d.eq(font.instruments.firstIndex(where: { $0 === r.instrument }) ?? -1, o.instrumentIndex, "\(label).instrumentIndex")
        d.eq(r.instrument.name, o.instrumentName, "\(label).instrumentName")
        d.eq(r.keyRangeStart, o.keyRangeStart, "\(label).keyRangeStart")
        d.eq(r.keyRangeEnd, o.keyRangeEnd, "\(label).keyRangeEnd")
        d.eq(r.velocityRangeStart, o.velocityRangeStart, "\(label).velocityRangeStart")
        d.eq(r.velocityRangeEnd, o.velocityRangeEnd, "\(label).velocityRangeEnd")
        d.eq(r.modulationLfoToPitch, o.modulationLfoToPitch, "\(label).modulationLfoToPitch")
        d.eq(r.vibratoLfoToPitch, o.vibratoLfoToPitch, "\(label).vibratoLfoToPitch")
        d.eq(r.modulationEnvelopeToPitch, o.modulationEnvelopeToPitch, "\(label).modulationEnvelopeToPitch")
        d.eq(r.modulationLfoToFilterCutoffFrequency, o.modulationLfoToFilterCutoffFrequency, "\(label).modLfoToFc")
        d.eq(r.modulationEnvelopeToFilterCutoffFrequency, o.modulationEnvelopeToFilterCutoffFrequency, "\(label).modEnvToFc")
        d.eq(r.keyNumberToModulationEnvelopeHold, o.keyNumberToModulationEnvelopeHold, "\(label).keyNumToModEnvHold")
        d.eq(r.keyNumberToModulationEnvelopeDecay, o.keyNumberToModulationEnvelopeDecay, "\(label).keyNumToModEnvDecay")
        d.eq(r.keyNumberToVolumeEnvelopeHold, o.keyNumberToVolumeEnvelopeHold, "\(label).keyNumToVolEnvHold")
        d.eq(r.keyNumberToVolumeEnvelopeDecay, o.keyNumberToVolumeEnvelopeDecay, "\(label).keyNumToVolEnvDecay")
        d.eq(r.coarseTune, o.coarseTune, "\(label).coarseTune")
        d.eq(r.fineTune, o.fineTune, "\(label).fineTune")
        d.eq(r.scaleTuning, o.scaleTuning, "\(label).scaleTuning")
        d.close(r.initialFilterCutoffFrequency, o.initialFilterCutoffFrequency, "\(label).initialFilterCutoffFrequency")
        d.close(r.initialFilterQ, o.initialFilterQ, "\(label).initialFilterQ")
        d.close(r.modulationLfoToVolume, o.modulationLfoToVolume, "\(label).modulationLfoToVolume")
        d.close(r.chorusEffectsSend, o.chorusEffectsSend, "\(label).chorusEffectsSend")
        d.close(r.reverbEffectsSend, o.reverbEffectsSend, "\(label).reverbEffectsSend")
        d.close(r.pan, o.pan, "\(label).pan")
        d.close(r.delayModulationLfo, o.delayModulationLfo, "\(label).delayModulationLfo")
        d.close(r.frequencyModulationLfo, o.frequencyModulationLfo, "\(label).frequencyModulationLfo")
        d.close(r.delayVibratoLfo, o.delayVibratoLfo, "\(label).delayVibratoLfo")
        d.close(r.frequencyVibratoLfo, o.frequencyVibratoLfo, "\(label).frequencyVibratoLfo")
        d.close(r.delayModulationEnvelope, o.delayModulationEnvelope, "\(label).delayModulationEnvelope")
        d.close(r.attackModulationEnvelope, o.attackModulationEnvelope, "\(label).attackModulationEnvelope")
        d.close(r.holdModulationEnvelope, o.holdModulationEnvelope, "\(label).holdModulationEnvelope")
        d.close(r.decayModulationEnvelope, o.decayModulationEnvelope, "\(label).decayModulationEnvelope")
        d.close(r.sustainModulationEnvelope, o.sustainModulationEnvelope, "\(label).sustainModulationEnvelope")
        d.close(r.releaseModulationEnvelope, o.releaseModulationEnvelope, "\(label).releaseModulationEnvelope")
        d.close(r.delayVolumeEnvelope, o.delayVolumeEnvelope, "\(label).delayVolumeEnvelope")
        d.close(r.attackVolumeEnvelope, o.attackVolumeEnvelope, "\(label).attackVolumeEnvelope")
        d.close(r.holdVolumeEnvelope, o.holdVolumeEnvelope, "\(label).holdVolumeEnvelope")
        d.close(r.decayVolumeEnvelope, o.decayVolumeEnvelope, "\(label).decayVolumeEnvelope")
        d.close(r.sustainVolumeEnvelope, o.sustainVolumeEnvelope, "\(label).sustainVolumeEnvelope")
        d.close(r.releaseVolumeEnvelope, o.releaseVolumeEnvelope, "\(label).releaseVolumeEnvelope")
        d.close(r.initialAttenuation, o.initialAttenuation, "\(label).initialAttenuation")
    }

    private func compareInstrumentRegion(
        _ r: InstrumentRegion, _ o: OracleDump.InstrumentRegionRecord, font: SoundFont,
        label: String, into d: inout Diff
    ) {
        d.eq(font.sampleHeaders.firstIndex(where: { $0 === r.sample }) ?? -1, o.sampleIndex, "\(label).sampleIndex")
        d.eq(r.sample.name, o.sampleName, "\(label).sampleName")
        d.eq(r.sampleStart, o.sampleStart, "\(label).sampleStart")
        d.eq(r.sampleEnd, o.sampleEnd, "\(label).sampleEnd")
        d.eq(r.sampleStartLoop, o.sampleStartLoop, "\(label).sampleStartLoop")
        d.eq(r.sampleEndLoop, o.sampleEndLoop, "\(label).sampleEndLoop")
        d.eq(r.startAddressOffset, o.startAddressOffset, "\(label).startAddressOffset")
        d.eq(r.endAddressOffset, o.endAddressOffset, "\(label).endAddressOffset")
        d.eq(r.startLoopAddressOffset, o.startLoopAddressOffset, "\(label).startLoopAddressOffset")
        d.eq(r.endLoopAddressOffset, o.endLoopAddressOffset, "\(label).endLoopAddressOffset")
        d.eq(loopModeCode(r.sampleModes), o.sampleModes, "\(label).sampleModes")
        d.eq(r.rootKey, o.rootKey, "\(label).rootKey")
        d.eq(r.exclusiveClass, o.exclusiveClass, "\(label).exclusiveClass")
        d.eq(r.keyRangeStart, o.keyRangeStart, "\(label).keyRangeStart")
        d.eq(r.keyRangeEnd, o.keyRangeEnd, "\(label).keyRangeEnd")
        d.eq(r.velocityRangeStart, o.velocityRangeStart, "\(label).velocityRangeStart")
        d.eq(r.velocityRangeEnd, o.velocityRangeEnd, "\(label).velocityRangeEnd")
        d.eq(r.modulationLfoToPitch, o.modulationLfoToPitch, "\(label).modulationLfoToPitch")
        d.eq(r.vibratoLfoToPitch, o.vibratoLfoToPitch, "\(label).vibratoLfoToPitch")
        d.eq(r.modulationEnvelopeToPitch, o.modulationEnvelopeToPitch, "\(label).modulationEnvelopeToPitch")
        d.eq(r.modulationLfoToFilterCutoffFrequency, o.modulationLfoToFilterCutoffFrequency, "\(label).modLfoToFc")
        d.eq(r.modulationEnvelopeToFilterCutoffFrequency, o.modulationEnvelopeToFilterCutoffFrequency, "\(label).modEnvToFc")
        d.eq(r.keyNumberToModulationEnvelopeHold, o.keyNumberToModulationEnvelopeHold, "\(label).keyNumToModEnvHold")
        d.eq(r.keyNumberToModulationEnvelopeDecay, o.keyNumberToModulationEnvelopeDecay, "\(label).keyNumToModEnvDecay")
        d.eq(r.keyNumberToVolumeEnvelopeHold, o.keyNumberToVolumeEnvelopeHold, "\(label).keyNumToVolEnvHold")
        d.eq(r.keyNumberToVolumeEnvelopeDecay, o.keyNumberToVolumeEnvelopeDecay, "\(label).keyNumToVolEnvDecay")
        d.eq(r.coarseTune, o.coarseTune, "\(label).coarseTune")
        d.eq(r.fineTune, o.fineTune, "\(label).fineTune")
        d.eq(r.scaleTuning, o.scaleTuning, "\(label).scaleTuning")
        d.close(r.initialFilterCutoffFrequency, o.initialFilterCutoffFrequency, "\(label).initialFilterCutoffFrequency")
        d.close(r.initialFilterQ, o.initialFilterQ, "\(label).initialFilterQ")
        d.close(r.modulationLfoToVolume, o.modulationLfoToVolume, "\(label).modulationLfoToVolume")
        d.close(r.chorusEffectsSend, o.chorusEffectsSend, "\(label).chorusEffectsSend")
        d.close(r.reverbEffectsSend, o.reverbEffectsSend, "\(label).reverbEffectsSend")
        d.close(r.pan, o.pan, "\(label).pan")
        d.close(r.delayModulationLfo, o.delayModulationLfo, "\(label).delayModulationLfo")
        d.close(r.frequencyModulationLfo, o.frequencyModulationLfo, "\(label).frequencyModulationLfo")
        d.close(r.delayVibratoLfo, o.delayVibratoLfo, "\(label).delayVibratoLfo")
        d.close(r.frequencyVibratoLfo, o.frequencyVibratoLfo, "\(label).frequencyVibratoLfo")
        d.close(r.delayModulationEnvelope, o.delayModulationEnvelope, "\(label).delayModulationEnvelope")
        d.close(r.attackModulationEnvelope, o.attackModulationEnvelope, "\(label).attackModulationEnvelope")
        d.close(r.holdModulationEnvelope, o.holdModulationEnvelope, "\(label).holdModulationEnvelope")
        d.close(r.decayModulationEnvelope, o.decayModulationEnvelope, "\(label).decayModulationEnvelope")
        d.close(r.sustainModulationEnvelope, o.sustainModulationEnvelope, "\(label).sustainModulationEnvelope")
        d.close(r.releaseModulationEnvelope, o.releaseModulationEnvelope, "\(label).releaseModulationEnvelope")
        d.close(r.delayVolumeEnvelope, o.delayVolumeEnvelope, "\(label).delayVolumeEnvelope")
        d.close(r.attackVolumeEnvelope, o.attackVolumeEnvelope, "\(label).attackVolumeEnvelope")
        d.close(r.holdVolumeEnvelope, o.holdVolumeEnvelope, "\(label).holdVolumeEnvelope")
        d.close(r.decayVolumeEnvelope, o.decayVolumeEnvelope, "\(label).decayVolumeEnvelope")
        d.close(r.sustainVolumeEnvelope, o.sustainVolumeEnvelope, "\(label).sustainVolumeEnvelope")
        d.close(r.releaseVolumeEnvelope, o.releaseVolumeEnvelope, "\(label).releaseVolumeEnvelope")
        d.close(r.initialAttenuation, o.initialAttenuation, "\(label).initialAttenuation")
    }

    private func comparePair(
        _ p: RegionPair, _ o: OracleDump.PairRecord, label: String, into d: inout Diff
    ) {
        d.eq(p.sampleStart, o.sampleStart, "\(label).sampleStart")
        d.eq(p.sampleEnd, o.sampleEnd, "\(label).sampleEnd")
        d.eq(p.sampleStartLoop, o.sampleStartLoop, "\(label).sampleStartLoop")
        d.eq(p.sampleEndLoop, o.sampleEndLoop, "\(label).sampleEndLoop")
        d.eq(loopModeCode(p.sampleModes), o.sampleModes, "\(label).sampleModes")
        d.eq(p.rootKey, o.rootKey, "\(label).rootKey")
        d.eq(p.exclusiveClass, o.exclusiveClass, "\(label).exclusiveClass")
        d.eq(p.modulationLfoToPitch, o.modulationLfoToPitch, "\(label).modulationLfoToPitch")
        d.eq(p.vibratoLfoToPitch, o.vibratoLfoToPitch, "\(label).vibratoLfoToPitch")
        d.eq(p.modulationEnvelopeToPitch, o.modulationEnvelopeToPitch, "\(label).modulationEnvelopeToPitch")
        d.eq(p.modulationLfoToFilterCutoffFrequency, o.modulationLfoToFilterCutoffFrequency, "\(label).modLfoToFc")
        d.eq(p.modulationEnvelopeToFilterCutoffFrequency, o.modulationEnvelopeToFilterCutoffFrequency, "\(label).modEnvToFc")
        d.eq(p.keyNumberToModulationEnvelopeHold, o.keyNumberToModulationEnvelopeHold, "\(label).keyNumToModEnvHold")
        d.eq(p.keyNumberToModulationEnvelopeDecay, o.keyNumberToModulationEnvelopeDecay, "\(label).keyNumToModEnvDecay")
        d.eq(p.keyNumberToVolumeEnvelopeHold, o.keyNumberToVolumeEnvelopeHold, "\(label).keyNumToVolEnvHold")
        d.eq(p.keyNumberToVolumeEnvelopeDecay, o.keyNumberToVolumeEnvelopeDecay, "\(label).keyNumToVolEnvDecay")
        d.eq(p.coarseTune, o.coarseTune, "\(label).coarseTune")
        d.eq(p.fineTune, o.fineTune, "\(label).fineTune")
        d.eq(p.scaleTuning, o.scaleTuning, "\(label).scaleTuning")
        d.close(p.modulationLfoToVolume, o.modulationLfoToVolume, "\(label).modulationLfoToVolume")
        d.close(p.chorusEffectsSend, o.chorusEffectsSend, "\(label).chorusEffectsSend")
        d.close(p.reverbEffectsSend, o.reverbEffectsSend, "\(label).reverbEffectsSend")
        d.close(p.pan, o.pan, "\(label).pan")
        d.close(p.initialFilterQ, o.initialFilterQ, "\(label).initialFilterQ")
        d.close(p.sustainModulationEnvelope, o.sustainModulationEnvelope, "\(label).sustainModulationEnvelope")
        d.close(p.sustainVolumeEnvelope, o.sustainVolumeEnvelope, "\(label).sustainVolumeEnvelope")
        d.close(p.initialAttenuation, o.initialAttenuation, "\(label).initialAttenuation")
        d.close(p.initialFilterCutoffFrequency, o.initialFilterCutoffFrequency, "\(label).initialFilterCutoffFrequency")
        d.close(p.delayModulationLfo, o.delayModulationLfo, "\(label).delayModulationLfo")
        d.close(p.frequencyModulationLfo, o.frequencyModulationLfo, "\(label).frequencyModulationLfo")
        d.close(p.delayVibratoLfo, o.delayVibratoLfo, "\(label).delayVibratoLfo")
        d.close(p.frequencyVibratoLfo, o.frequencyVibratoLfo, "\(label).frequencyVibratoLfo")
        d.close(p.delayModulationEnvelope, o.delayModulationEnvelope, "\(label).delayModulationEnvelope")
        d.close(p.attackModulationEnvelope, o.attackModulationEnvelope, "\(label).attackModulationEnvelope")
        d.close(p.holdModulationEnvelope, o.holdModulationEnvelope, "\(label).holdModulationEnvelope")
        d.close(p.decayModulationEnvelope, o.decayModulationEnvelope, "\(label).decayModulationEnvelope")
        d.close(p.releaseModulationEnvelope, o.releaseModulationEnvelope, "\(label).releaseModulationEnvelope")
        d.close(p.delayVolumeEnvelope, o.delayVolumeEnvelope, "\(label).delayVolumeEnvelope")
        d.close(p.attackVolumeEnvelope, o.attackVolumeEnvelope, "\(label).attackVolumeEnvelope")
        d.close(p.holdVolumeEnvelope, o.holdVolumeEnvelope, "\(label).holdVolumeEnvelope")
        d.close(p.decayVolumeEnvelope, o.decayVolumeEnvelope, "\(label).decayVolumeEnvelope")
        d.close(p.releaseVolumeEnvelope, o.releaseVolumeEnvelope, "\(label).releaseVolumeEnvelope")
    }
}

/// Canonical loop-mode code shared with the oracle: 0 = noLoop, 1 = continuous, 2 = loopUntilNoteOff.
func loopModeCode(_ mode: LoopMode) -> Int {
    switch mode {
    case .noLoop: return 0
    case .continuous: return 1
    case .loopUntilNoteOff: return 2
    }
}
