import Testing
@testable import SwiftySynth

struct ChannelTests {
    /// Only formula-independent defaults are asserted here (a zero raw value is zero under
    /// any linear scaling; pitch bend is centered by definition). The exact scaling
    /// constants are validated end-to-end by G2 — a wrong volume/expression/pan scale
    /// shifts the whole waveform and cannot pass the PCM gate.
    @Test func resetEstablishesMidiDefaults() {
        let channel = Channel(isPercussionChannel: false)
        #expect(channel.bankNumber == 0)
        #expect(channel.patchNumber == 0)
        #expect(channel.modulation == 0)          // CC1 = 0
        #expect(channel.pitchBend == 0)           // centered
        #expect(channel.pitchBendRange == 2)      // RPN 0 default: ±2 semitones
        #expect(channel.tune == 0)
        #expect(abs(channel.pan) < 0.05)          // CC10 = 64 ≈ center under Channel.cs scaling
        #expect(channel.volume > 0)               // CC7 = 100
        #expect(channel.expression > 0)           // CC11 = 127
        #expect(!channel.holdPedal)               // CC64 up
    }

    @Test func resetIsIdempotent() {
        let channel = Channel(isPercussionChannel: false)
        let volume = channel.volume
        channel.reset()
        #expect(channel.volume == volume)
        #expect(channel.pitchBend == 0)
    }

    @Test func percussionChannelDefaultsToBank128AndBankSelectAdds128() {
        let percussion = Channel(isPercussionChannel: true)
        #expect(percussion.bankNumber == 128)
        percussion.setBank(1)
        #expect(percussion.bankNumber == 129, "percussion bank select adds 128 (Channel.cs SetBank)")

        let melodic = Channel(isPercussionChannel: false)
        #expect(melodic.bankNumber == 0)
        melodic.setBank(1)
        #expect(melodic.bankNumber == 1)
        melodic.setPatch(24)
        #expect(melodic.patchNumber == 24)
    }

    /// Coarse writes bits 7–13, fine writes bits 0–6, each preserving the
    /// other half — assertions mirror the getters' own scaling expressions,
    /// so they are exact float comparisons.
    @Test func coarseAndFinePackIntoFourteenBits() {
        let channel = Channel(isPercussionChannel: false)

        channel.setVolumeCoarse(80)
        channel.setVolumeFine(64)
        #expect(channel.volume == Float((80 << 7) | 64) / Float(16_383))

        channel.setModulationCoarse(1)
        channel.setModulationFine(3)
        #expect(channel.modulation == (Float(50) / Float(16_383)) * Float((1 << 7) | 3))

        channel.setPanCoarse(127)
        channel.setPanFine(127)
        #expect(channel.pan == (Float(100) / Float(16_383)) * Float(16_383) - 50)   // hard right = +50

        channel.setExpressionCoarse(100)
        #expect(channel.expression == Float(100 << 7) / Float(16_383))
    }

    @Test func holdPedalThresholdIs64() {
        let channel = Channel(isPercussionChannel: false)
        channel.setHoldPedal(63)
        #expect(!channel.holdPedal)
        channel.setHoldPedal(64)
        #expect(channel.holdPedal)
    }

    @Test func reverbAndChorusSendsScaleFrom7Bit() {
        let channel = Channel(isPercussionChannel: false)
        channel.setReverbSend(127)
        channel.setChorusSend(64)
        #expect(channel.reverbSend == 1.0)
        #expect(channel.chorusSend == Float(64) / Float(127))
    }

    /// Data entry dispatches on the last RPN selection (0 = pitch-bend range,
    /// 1 = fine tune, 2 = coarse tune); with no RPN selected (-1 after reset)
    /// it is a no-op. Canonical C# — deliberately NO NRPN handling.
    @Test func dataEntryDispatchesOnRpnSelection() {
        let channel = Channel(isPercussionChannel: false)

        channel.dataEntryCoarse(12)
        #expect(channel.pitchBendRange == 2, "data entry without an RPN selection must be a no-op")

        channel.setRpnCoarse(0)
        channel.setRpnFine(0)
        channel.dataEntryCoarse(12)                // 12 semitones
        channel.dataEntryFine(50)                  // + 50 cents
        #expect(channel.pitchBendRange == Float(12) + 0.01 * Float(50))

        channel.setRpnFine(1)                      // RPN 1: fine tune
        channel.dataEntryCoarse(72)
        channel.dataEntryFine(0)
        #expect(channel.tune == 0.125, "fineTune 72<<7 = 9216 → (9216 − 8192)/8192 = +0.125 semitones")

        channel.setRpnFine(2)                      // RPN 2: coarse tune
        channel.dataEntryCoarse(66)                // 64-centered → +2 semitones
        #expect(channel.tune == 2.125)
    }

    /// C#'s unchecked `(short)` cast truncates; the Swift port must use
    /// `truncatingIfNeeded` or this call chain would trap. rpn == -1 →
    /// (-1 & 0xFF80) | 5 = 65413 → (short)-123: negative, selects no RPN.
    @Test func rpnFineOnUnsetRpnMatchesCSharpTruncation() {
        let channel = Channel(isPercussionChannel: false)
        channel.setRpnFine(5)
        channel.dataEntryCoarse(12)
        #expect(channel.pitchBendRange == 2, "a garbage (negative) RPN must not dispatch data entry")
    }

    @Test func pitchBendCombinesFourteenBitValueAndRange() {
        let channel = Channel(isPercussionChannel: false)
        channel.setPitchBend(0, 96)                // (0 | 96<<7) − 8192 = +4096 → +0.5 of range
        #expect(channel.pitchBend == 1.0, "default range 2 × +0.5 = +1 semitone")
        channel.setPitchBend(0, 0)                 // −8192 → −1.0 of range
        #expect(channel.pitchBend == -2.0)
    }

    /// `ResetAllControllers` is PARTIAL by spec: modulation, expression, hold
    /// pedal, RPN, and pitch bend reset; bank/patch, volume, pan, effects
    /// sends, and tuning survive.
    @Test func resetAllControllersIsPartial() {
        let channel = Channel(isPercussionChannel: false)
        channel.setModulationCoarse(50)
        channel.setVolumeCoarse(32)
        channel.setPanCoarse(0)
        channel.setHoldPedal(127)
        channel.setPitchBend(0, 96)
        channel.resetAllControllers()

        #expect(channel.modulation == 0)
        #expect(channel.pitchBend == 0)
        #expect(!channel.holdPedal)
        #expect(channel.expression == Float(127 << 7) / Float(16_383))
        #expect(channel.volume == Float(32 << 7) / Float(16_383), "volume survives resetAllControllers")
        #expect(channel.pan == -50, "pan survives resetAllControllers")
    }
}
