import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic tests for the faithful raw-MIDI dispatch over the synthetic
/// font; the channel state machine is observable via @testable access to
/// `Synthesizer.channels`. PCM consequences of the same messages are pinned
/// by G2-multi against the oracle.
struct MidiDispatchTests {
    private func makeSynth() throws -> Synthesizer {
        let font = try SoundFont(data: SyntheticSF2.minimal())
        // These tests assert only channel-state structure, never PCM, so the
        // effects bus is disabled to avoid allocating an unused chorus table.
        return try Synthesizer(
            soundFont: font,
            settings: SynthesizerSettings(sampleRate: 44_100, enableReverbAndChorus: false))
    }

    @Test func controllerMessagesUpdateOnlyTheirChannel() throws {
        let synth = try makeSynth()

        synth.processMidiMessage(channel: 3, command: 0xB0, data1: 0x07, data2: 32)   // volume coarse
        #expect(synth.channels[3].volume == Float(32 << 7) / Float(16_383))

        synth.processMidiMessage(channel: 3, command: 0xB0, data1: 0x0A, data2: 0)    // pan coarse: hard left
        #expect(synth.channels[3].pan == -50)

        synth.processMidiMessage(channel: 3, command: 0xB0, data1: 0x0B, data2: 64)   // expression coarse
        #expect(synth.channels[3].expression == Float(64 << 7) / Float(16_383))

        synth.processMidiMessage(channel: 3, command: 0xB0, data1: 0x40, data2: 127)  // hold pedal down
        #expect(synth.channels[3].holdPedal)

        synth.processMidiMessage(channel: 3, command: 0xB0, data1: 0x5B, data2: 100)  // reverb send
        #expect(synth.channels[3].reverbSend == Float(100) / Float(127))

        synth.processMidiMessage(channel: 3, command: 0xB0, data1: 0x5D, data2: 50)   // chorus send
        #expect(synth.channels[3].chorusSend == Float(50) / Float(127))

        // A neighboring channel is untouched.
        #expect(synth.channels[2].volume == Float(100 << 7) / Float(16_383))
        #expect(!synth.channels[2].holdPedal)
    }

    @Test func fineControllersReachTheFinePaths() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x07, data2: 80)   // volume coarse
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x27, data2: 64)   // volume fine
        #expect(synth.channels[0].volume == Float((80 << 7) | 64) / Float(16_383))

        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x01, data2: 1)    // modulation coarse
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x21, data2: 3)    // modulation fine (C# uses 0x21)
        #expect(synth.channels[0].modulation == (Float(50) / Float(16_383)) * Float((1 << 7) | 3))

        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x2A, data2: 127)  // pan fine
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x2B, data2: 1)    // expression fine
        #expect(synth.channels[0].pan == (Float(100) / Float(16_383)) * Float((64 << 7) | 127) - 50)
        #expect(synth.channels[0].expression == Float((127 << 7) | 1) / Float(16_383))
    }

    @Test func programAndBankSelectResolveThroughChannelState() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 0, command: 0xC0, data1: 24, data2: 0)      // program change
        #expect(synth.channels[0].patchNumber == 24)

        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x00, data2: 2)    // bank select
        #expect(synth.channels[0].bankNumber == 2)

        synth.processMidiMessage(channel: 9, command: 0xB0, data1: 0x00, data2: 1)    // bank select, percussion
        #expect(synth.channels[9].bankNumber == 129, "percussion bank select adds 128")
    }

    @Test func rpnDataEntrySetsPitchBendRangeAndScalesBend() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 1, command: 0xB0, data1: 0x65, data2: 0)    // RPN coarse
        synth.processMidiMessage(channel: 1, command: 0xB0, data1: 0x64, data2: 0)    // RPN fine → RPN 0
        synth.processMidiMessage(channel: 1, command: 0xB0, data1: 0x06, data2: 12)   // data entry coarse
        #expect(synth.channels[1].pitchBendRange == 12)

        synth.processMidiMessage(channel: 1, command: 0xE0, data1: 0, data2: 96)      // bend +4096/8192
        #expect(synth.channels[1].pitchBend == 6.0, "range 12 × bend +0.5 = +6 semitones")
    }

    @Test func resetAllControllersViaCCIsPartial() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x01, data2: 50)   // modulation
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x07, data2: 32)   // volume
        synth.processMidiMessage(channel: 0, command: 0xE0, data1: 0, data2: 96)      // bend
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x79, data2: 0)    // reset all controllers

        #expect(synth.channels[0].modulation == 0)
        #expect(synth.channels[0].pitchBend == 0)
        #expect(synth.channels[0].expression == Float(127 << 7) / Float(16_383))
        #expect(synth.channels[0].volume == Float(32 << 7) / Float(16_383), "volume is NOT reset by CC 0x79")
    }

    @Test func noteMessagesStartReleaseAndKillVoices() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 0, command: 0x90, data1: 60, data2: 100)    // note on
        #expect(synth.activeVoiceCount == 1)

        synth.processMidiMessage(channel: 0, command: 0x80, data1: 60, data2: 0)      // note off → release
        #expect(synth.activeVoiceCount == 1, "released voices die on render, not on dispatch")
        #expect(synth.voices[0].priority > 0)

        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x78, data2: 0)    // all sound off → kill
        #expect(synth.voices[0].priority == 0, "all-sound-off kills: priority must read 0")
    }

    @Test func velocityZeroNoteOnDispatchesAsNoteOff() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 0, command: 0x90, data1: 60, data2: 100)
        synth.processMidiMessage(channel: 0, command: 0x90, data1: 60, data2: 0)
        #expect(synth.activeVoiceCount == 1)
        #expect(synth.voices[0].priority > 0, "vel-0 note-on releases (does not kill)")
    }

    @Test func outOfRangeChannelsAndUnhandledMessagesAreIgnored() throws {
        let synth = try makeSynth()
        synth.processMidiMessage(channel: 16, command: 0x90, data1: 60, data2: 100)
        synth.processMidiMessage(channel: -1, command: 0x90, data1: 60, data2: 100)
        synth.processMidiMessage(channel: 0, command: 0xA0, data1: 60, data2: 100)    // poly aftertouch: unhandled
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x62, data2: 1)    // NRPN fine: unhandled (canonical C#)
        synth.processMidiMessage(channel: 0, command: 0xB0, data1: 0x63, data2: 1)    // NRPN coarse: unhandled (canonical C#)
        #expect(synth.activeVoiceCount == 0)
        #expect(synth.channels[0].volume == Float(100 << 7) / Float(16_383), "nothing may change")
    }
}
