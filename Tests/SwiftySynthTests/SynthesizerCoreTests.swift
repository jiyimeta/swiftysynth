import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic full-Synthesizer structural tests over the synthetic font
/// (1 preset: bank 0 / patch 0 "Piano"). Rendering fidelity is G2/G2-multi's
/// job; these pin the structure: 16 channels, preset resolution + GM
/// fallback, settings propagation, and the reset/note-off-all lifecycles.
struct SynthesizerCoreTests {
    private func makeSynth(settings: SynthesizerSettings? = nil) throws -> Synthesizer {
        let font = try SoundFont(data: SyntheticSF2.minimal())
        if let settings {
            return try Synthesizer(soundFont: font, settings: settings)
        }
        return try Synthesizer(soundFont: font, sampleRate: 44_100)
    }

    @Test func initBuildsSixteenChannelsWithPercussionAtNine() throws {
        let synth = try makeSynth()
        #expect(Synthesizer.channelCount == 16)
        #expect(Synthesizer.percussionChannel == 9)
        #expect(synth.channels.count == 16)
        for (index, channel) in synth.channels.enumerated() {
            #expect(channel.isPercussionChannel == (index == 9))
        }
        #expect(synth.channels[9].bankNumber == 128)
        #expect(synth.maximumPolyphony == 64, "convenience init uses canonical default settings")
        #expect(synth.blockSize == 64)
        #expect(synth.masterVolume == 0.5)
        #expect(synth.activeVoiceCount == 0)
    }

    @Test func settingsArePropagated() throws {
        let settings = try SynthesizerSettings(
            sampleRate: 48_000, blockSize: 128, maximumPolyphony: 32, enableReverbAndChorus: false)
        let synth = try makeSynth(settings: settings)
        #expect(synth.sampleRate == 48_000)
        #expect(synth.blockSize == 128)
        #expect(synth.maximumPolyphony == 32)
        #expect(synth.enableReverbAndChorus == false)
    }

    @Test func unknownProgramFallsBackToDefaultPreset() throws {
        let synth = try makeSynth()
        synth.channels[0].setPatch(5)                 // only 0:0 exists → GM miss → default
        synth.noteOn(key: 60, velocity: 100, on: 0)
        #expect(synth.activeVoiceCount == 1, "GM fallback chain must end at the default preset and still sound")
    }

    @Test func percussionChannelFallsBackToDefaultPreset() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 36, velocity: 100, on: 9)   // bank 128 missing → 128:0 missing → default
        #expect(synth.activeVoiceCount == 1)
    }

    @Test func outOfRangeChannelsAreIgnored() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 16)
        synth.noteOn(key: 60, velocity: 100, on: -1)
        synth.noteOff(key: 60, on: 16)                // must not trap either
        #expect(synth.activeVoiceCount == 0)
    }

    @Test func velocityZeroNoteOnIsNoteOff() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        #expect(synth.activeVoiceCount == 1)
        synth.noteOn(key: 60, velocity: 0, on: 0)     // Synthesizer.cs: vel 0 → NoteOff
        // Released, not killed: the voice stays active until processed, and
        // its priority is still a sustained-stage value.
        #expect(synth.activeVoiceCount == 1)
        #expect(synth.voices[0].priority > 0)
    }

    @Test func noteOffAllImmediateClearsAndNonImmediateReleases() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        synth.noteOn(key: 62, velocity: 100, on: 1)
        #expect(synth.activeVoiceCount == 2)
        synth.noteOffAll(immediate: true)
        #expect(synth.activeVoiceCount == 0)

        synth.noteOn(key: 60, velocity: 100, on: 0)
        synth.noteOffAll(immediate: false)
        #expect(synth.activeVoiceCount == 1, "non-immediate note-off-all releases; the voice dies on render")
    }

    @Test func channelScopedNoteOffAllKillsOrReleasesOnlyThatChannel() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        synth.noteOn(key: 62, velocity: 100, on: 1)

        synth.noteOffAll(channel: 1, immediate: true)  // kill: priority drops to 0
        #expect(synth.activeVoiceCount == 2, "a killed voice leaves the pool only on its next process()")
        let priorities = (0..<synth.voices.activeVoiceCount).map { i -> (channel: Int, priority: Float) in
            (synth.voices[i].channel, synth.voices[i].priority)
        }
        for entry in priorities {
            if entry.channel == 1 {
                #expect(entry.priority == 0, "channel-1 voice must be killed")
            } else {
                #expect(entry.priority > 0, "channel-0 voice must be untouched")
            }
        }
    }

    @Test func resetRestoresChannelDefaultsAndClearsVoices() throws {
        let synth = try makeSynth()
        synth.noteOn(key: 60, velocity: 100, on: 0)
        synth.channels[0].setVolumeCoarse(32)
        synth.channels[9].setBank(1)                  // 129
        synth.reset()
        #expect(synth.activeVoiceCount == 0)
        #expect(synth.channels[0].volume == Float(100 << 7) / Float(16_383))
        #expect(synth.channels[9].bankNumber == 128, "percussion channel resets to bank 128")
    }

    @Test func resetAllControllersIsChannelScopedOrGlobal() throws {
        let synth = try makeSynth()
        synth.channels[2].setModulationCoarse(50)
        synth.channels[4].setModulationCoarse(50)
        synth.resetAllControllers(channel: 2)
        #expect(synth.channels[2].modulation == 0)
        #expect(synth.channels[4].modulation != 0)
        synth.resetAllControllers()
        #expect(synth.channels[4].modulation == 0)
    }
}
