import Testing
@testable import SwiftySynth

struct ModulationEnvelopeTests {
    private let blockSeconds = Float(64) / 44_100

    @Test func dahdssStageShape() {
        let env = ModulationEnvelope(sampleRate: 44_100, blockSize: 64)
        env.start(delay: 2 * blockSeconds, attack: 4 * blockSeconds,
                  hold: 4 * blockSeconds, decay: 100 * blockSeconds,
                  sustain: 0.4, release: 10 * blockSeconds)

        env.process()
        #expect(env.value == 0)                      // delay

        for _ in 0..<3 { env.process() }
        #expect(env.value > 0)                       // mid-attack
        #expect(env.value < 1)

        for _ in 0..<3 { env.process() }
        #expect(env.value >= 0.999)                  // hold

        for _ in 0..<123 { env.process() }           // decay finished
        #expect(abs(env.value - 0.4) < 0.05, "expected sustain plateau, got \(env.value)")
    }

    @Test func releaseDrivesValueTowardZero() {
        let env = ModulationEnvelope(sampleRate: 44_100, blockSize: 64)
        env.start(delay: 0, attack: blockSeconds, hold: 4 * blockSeconds,
                  decay: 100 * blockSeconds, sustain: 0.8, release: 10 * blockSeconds)
        for _ in 0..<4 { env.process() }
        #expect(env.value > 0.9)
        env.release()
        var previous = env.value
        for _ in 0..<200 {
            env.process()
            #expect(env.value <= previous + 1e-6)
            previous = env.value
        }
        #expect(env.value < 0.05, "mod envelope must approach zero after release, got \(env.value)")
    }
}
