import Testing
@testable import SwiftySynth

struct ChannelTests {
    /// Only formula-independent defaults are asserted here (a zero raw value is zero under
    /// any linear scaling; pitch bend is centered by definition). The exact scaling
    /// constants are validated end-to-end by G2 — a wrong volume/expression/pan scale
    /// shifts the whole waveform and cannot pass the PCM gate.
    @Test func resetEstablishesMidiDefaults() {
        let channel = Channel()
        #expect(channel.bankNumber == 0)
        #expect(channel.patchNumber == 0)
        #expect(channel.modulation == 0)          // CC1 = 0
        #expect(channel.pitchBend == 0)           // centered
        #expect(channel.pitchBendRange == 2)      // RPN 0 default: ±2 semitones
        #expect(channel.tune == 0)
        #expect(abs(channel.pan) < 0.05)          // CC10 = 64 ≈ center under Channel.cs scaling
        #expect(channel.volume > 0)               // CC7 = 100
        #expect(channel.expression > 0)           // CC11 = 127
    }

    @Test func resetIsIdempotent() {
        let channel = Channel()
        let volume = channel.volume
        channel.reset()
        #expect(channel.volume == volume)
        #expect(channel.pitchBend == 0)
    }
}
