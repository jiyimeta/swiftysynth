import Testing
@testable import MeltySynth

struct LfoTests {
    @Test func holdsZeroDuringDelay() {
        let lfo = Lfo(sampleRate: 44_100, blockSize: 64)
        lfo.start(delay: Float(10 * 64) / 44_100, frequency: 100)
        for _ in 0..<9 {
            lfo.process()
            #expect(lfo.value == 0)
        }
    }

    @Test func triangleTimingAndRange() {
        let lfo = Lfo(sampleRate: 44_100, blockSize: 64)
        // Period = 4096 samples = 64 blocks → quarter period = 16 blocks.
        lfo.start(delay: 0, frequency: 44_100.0 / 4_096.0)
        var values = [Float]()
        for _ in 0..<64 {
            lfo.process()
            values.append(lfo.value)
        }
        #expect(values.allSatisfy { $0 >= -1.001 && $0 <= 1.001 })
        // Peak ≈ +1 around a quarter period (±4 blocks of tolerance for block quantization
        // and the C# file's exact phase convention).
        #expect(values[11...19].max()! > 0.85, "expected +1 peak near block 16, got \(values[11...19].max()!)")
        // Near zero around the half period, descending.
        #expect(abs(values[31]) < 0.2, "expected ~0 near block 32, got \(values[31])")
        // Trough ≈ −1 around three quarters.
        #expect(values[43...51].min()! < -0.85, "expected −1 trough near block 48, got \(values[43...51].min()!)")
    }
}
