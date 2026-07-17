import Foundation
import Testing
@testable import SwiftySynth

/// Hermetic. Proves the idiomatic `MidiMessage` layer dispatches
/// BYTE-IDENTICALLY to the faithful raw `processMidiMessage` path (full-port
/// spec §6): every case maps to exactly one raw call with the same wire
/// values, pinned two ways — full channel-state equality after mirrored
/// scripts, and bit-exact PCM from twin synthesizers driven raw-vs-enum.
/// The wrapper performs no arithmetic, so `==` (not a tolerance) is the bar.
struct MidiMessageTests {
    private func makeSynth(effects: Bool = false) throws -> Synthesizer {
        let font = try SoundFont(data: SyntheticSF2.minimal())
        return try Synthesizer(
            soundFont: font,
            settings: SynthesizerSettings(sampleRate: 44_100, enableReverbAndChorus: effects))
    }

    /// Every raw-visible channel property, compared exactly (Float `==` —
    /// identical inputs through identical code must give identical bits).
    private func expectChannelsEqual(_ a: Synthesizer, _ b: Synthesizer, step: Int) {
        for i in 0..<Synthesizer.channelCount {
            let x = a.channels[i]
            let y = b.channels[i]
            #expect(x.bankNumber == y.bankNumber, "step \(step) channel \(i) bank")
            #expect(x.patchNumber == y.patchNumber, "step \(step) channel \(i) patch")
            #expect(x.modulation == y.modulation, "step \(step) channel \(i) modulation")
            #expect(x.volume == y.volume, "step \(step) channel \(i) volume")
            #expect(x.pan == y.pan, "step \(step) channel \(i) pan")
            #expect(x.expression == y.expression, "step \(step) channel \(i) expression")
            #expect(x.holdPedal == y.holdPedal, "step \(step) channel \(i) holdPedal")
            #expect(x.reverbSend == y.reverbSend, "step \(step) channel \(i) reverbSend")
            #expect(x.chorusSend == y.chorusSend, "step \(step) channel \(i) chorusSend")
            #expect(x.pitchBendRange == y.pitchBendRange, "step \(step) channel \(i) pitchBendRange")
            #expect(x.tune == y.tune, "step \(step) channel \(i) tune")
            #expect(x.pitchBend == y.pitchBend, "step \(step) channel \(i) pitchBend")
        }
        #expect(a.activeVoiceCount == b.activeVoiceCount, "step \(step) activeVoiceCount")
    }

    /// The idiomatic ↔ raw wire pairs — every enum case, the channel-mode
    /// CCs, the RPN → data-entry sequence, the vel-0 note-off convention,
    /// and the 14-bit pitch-bend split (data1 = low 7, data2 = high 7).
    private static let pairs: [(message: MidiMessage, command: Int, data1: Int, data2: Int)] = [
        (.programChange(0), 0xC0, 0, 0),
        (.controlChange(controller: 0x00, value: 0), 0xB0, 0x00, 0),      // bank select
        (.controlChange(controller: 0x07, value: 90), 0xB0, 0x07, 90),    // volume coarse
        (.controlChange(controller: 0x0A, value: 20), 0xB0, 0x0A, 20),    // pan coarse
        (.controlChange(controller: 0x0B, value: 101), 0xB0, 0x0B, 101),  // expression coarse
        (.controlChange(controller: 0x01, value: 33), 0xB0, 0x01, 33),    // modulation coarse
        (.controlChange(controller: 0x40, value: 127), 0xB0, 0x40, 127),  // hold pedal down
        (.controlChange(controller: 0x65, value: 0), 0xB0, 0x65, 0),      // RPN coarse
        (.controlChange(controller: 0x64, value: 0), 0xB0, 0x64, 0),      // RPN fine → RPN 0
        (.controlChange(controller: 0x06, value: 4), 0xB0, 0x06, 4),      // data entry: bend range 4
        (.controlChange(controller: 0x5B, value: 70), 0xB0, 0x5B, 70),    // reverb send
        (.controlChange(controller: 0x5D, value: 30), 0xB0, 0x5D, 30),    // chorus send
        (.pitchBend(10_000), 0xE0, 10_000 & 0x7F, (10_000 >> 7) & 0x7F),
        (.pitchBend(0), 0xE0, 0, 0),
        (.pitchBend(16_383), 0xE0, 0x7F, 0x7F),
        (.pitchBend(8_192), 0xE0, 0, 64),                                  // center
        (.noteOn(key: 60, velocity: 100), 0x90, 60, 100),
        (.noteOn(key: 64, velocity: 0), 0x90, 64, 0),                      // vel-0 == note off
        (.noteOff(key: 60), 0x80, 60, 64),
        (.controlChange(controller: 0x78, value: 0), 0xB0, 0x78, 0),      // all sound off
        (.controlChange(controller: 0x79, value: 0), 0xB0, 0x79, 0),      // reset all controllers
        (.controlChange(controller: 0x7B, value: 0), 0xB0, 0x7B, 0),      // all notes off
    ]

    /// The whole script on ONE channel — the stateful sequences (RPN select
    /// → data entry; bend with range 4 live; noteOn → noteOff) actually
    /// exercise the state machine on both sides.
    @Test func channelStateMatchesRawDispatchOnOneChannel() throws {
        let raw = try makeSynth()
        let idiomatic = try makeSynth()
        for (i, pair) in Self.pairs.enumerated() {
            raw.processMidiMessage(channel: 3, command: pair.command, data1: pair.data1, data2: pair.data2)
            idiomatic.send(pair.message, to: 3)
            expectChannelsEqual(raw, idiomatic, step: i)
        }
    }

    /// The same pairs spread across all 16 channels (incl. percussion 9) —
    /// the channel argument reaches the raw path unchanged.
    @Test func channelStateMatchesRawDispatchAcrossChannels() throws {
        let raw = try makeSynth()
        let idiomatic = try makeSynth()
        for (i, pair) in Self.pairs.enumerated() {
            let channel = i % Synthesizer.channelCount
            raw.processMidiMessage(channel: channel, command: pair.command, data1: pair.data1, data2: pair.data2)
            idiomatic.send(pair.message, to: channel)
            expectChannelsEqual(raw, idiomatic, step: i)
        }
    }

    private func render(_ synth: Synthesizer, frames: Int) -> ([Float], [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l, right: r)
            }
        }
        return (left, right)
    }

    /// Twin synthesizers, EFFECTS ON, one driven raw and one via `send`,
    /// rendering between messages: the PCM must be BIT-IDENTICAL at every
    /// stage, and the script must actually produce audio (a silent pass
    /// proves nothing).
    @Test func renderedPCMIsBitIdentical() throws {
        let raw = try makeSynth(effects: true)
        let idiomatic = try makeSynth(effects: true)

        let script: [(message: MidiMessage, command: Int, data1: Int, data2: Int)] = [
            (.programChange(0), 0xC0, 0, 0),
            (.controlChange(controller: 0x07, value: 100), 0xB0, 0x07, 100),
            (.controlChange(controller: 0x0A, value: 30), 0xB0, 0x0A, 30),
            (.controlChange(controller: 0x65, value: 0), 0xB0, 0x65, 0),
            (.controlChange(controller: 0x64, value: 0), 0xB0, 0x64, 0),
            (.controlChange(controller: 0x06, value: 4), 0xB0, 0x06, 4),
            (.controlChange(controller: 0x5B, value: 80), 0xB0, 0x5B, 80),
            (.controlChange(controller: 0x5D, value: 40), 0xB0, 0x5D, 40),
            (.noteOn(key: 60, velocity: 100), 0x90, 60, 100),
            (.noteOn(key: 64, velocity: 90), 0x90, 64, 90),
            (.pitchBend(10_000), 0xE0, 10_000 & 0x7F, (10_000 >> 7) & 0x7F),
            (.noteOff(key: 60), 0x80, 60, 64),
        ]

        var peak: Float = 0
        for (i, step) in script.enumerated() {
            raw.processMidiMessage(channel: 0, command: step.command, data1: step.data1, data2: step.data2)
            idiomatic.send(step.message, to: 0)
            let (rl, rr) = render(raw, frames: 512)
            let (il, ir) = render(idiomatic, frames: 512)
            #expect(rl == il, "step \(i) left PCM diverged")
            #expect(rr == ir, "step \(i) right PCM diverged")
            peak = max(peak, rl.map(abs).max() ?? 0, rr.map(abs).max() ?? 0)
        }
        // Release tail after the remaining noteOff, still bit-identical.
        raw.processMidiMessage(channel: 0, command: 0x80, data1: 64, data2: 64)
        idiomatic.send(.noteOff(key: 64), to: 0)
        let (rl, rr) = render(raw, frames: 4_096)
        let (il, ir) = render(idiomatic, frames: 4_096)
        #expect(rl == il, "tail left PCM diverged")
        #expect(rr == ir, "tail right PCM diverged")
        peak = max(peak, rl.map(abs).max() ?? 0)
        #expect(peak > 0, "the script must actually produce audio")
    }

    /// Out-of-range channels are ignored exactly like the raw path (guard
    /// and return — no trap, no state change).
    @Test func outOfRangeChannelIsIgnoredLikeRaw() throws {
        let synth = try makeSynth()
        synth.send(.noteOn(key: 60, velocity: 100), to: 16)
        synth.send(.noteOn(key: 60, velocity: 100), to: -1)
        #expect(synth.activeVoiceCount == 0)
    }
}
