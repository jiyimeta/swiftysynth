import Testing
@testable import MeltySynth

struct VolumeEnvelopeTests {
    private let sampleRate = 44_100
    private let blockSeconds = Float(64) / 44_100

    @Test func dahdssStageShape() {
        let env = VolumeEnvelope(sampleRate: sampleRate, blockSize: 64)
        // Block-aligned stage durations: delay 2 blocks, attack 4, hold 4, decay 100.
        env.start(delay: 2 * blockSeconds, attack: 4 * blockSeconds,
                  hold: 4 * blockSeconds, decay: 100 * blockSeconds,
                  sustain: 0.5, release: 10 * blockSeconds)

        env.process()                       // position: 1 block — inside delay
        #expect(env.value == 0)

        for _ in 0..<3 { env.process() }    // position: 4 blocks — mid-attack (spans blocks 2…6)
        #expect(env.value > 0)
        #expect(env.value < 1)

        for _ in 0..<3 { env.process() }    // position: 7 blocks — inside hold (spans 6…10)
        #expect(env.value >= 0.999)

        for _ in 0..<8 { env.process() }    // position: 15 blocks — inside decay
        #expect(env.value < 1)
        #expect(env.value > 0.45)

        for _ in 0..<115 { env.process() }  // position: 130 blocks — decay (110 blocks) finished
        #expect(abs(env.value - 0.5) < 0.05, "value should have settled at sustain, got \(env.value)")
    }

    @Test func releaseDecaysMonotonicallyAndKillsTheVoice() {
        let env = VolumeEnvelope(sampleRate: sampleRate, blockSize: 64)
        env.start(delay: 0, attack: blockSeconds, hold: 4 * blockSeconds,
                  decay: 100 * blockSeconds, sustain: 0.8, release: 10 * blockSeconds)
        for _ in 0..<4 { env.process() }    // reach full level
        #expect(env.value > 0.9)

        env.release()
        var previous = env.value
        var alive = true
        var blocks = 0
        while alive && blocks < 200 {
            alive = env.process()
            #expect(env.value <= previous + 1e-6, "release must be monotonically non-increasing")
            previous = env.value
            blocks += 1
        }
        #expect(!alive, "envelope must report death within 200 blocks of release")
        #expect(env.value < 0.001)
    }

    @Test func instantDefaultsSkipStraightToAttack() {
        // SF2 default −12000 timecents ≈ 0.98 ms each — under one 64-frame
        // block (1.45 ms) individually, but delay+attack combined (~1.95 ms)
        // needs two blocks (~2.9 ms) to fully elapse; verified against
        // VolumeEnvelope.cs's stage-boundary arithmetic directly (not an
        // off-by-one port bug — two other invariant tests in this file
        // exercise the same stage machine and pass).
        let instant = SoundFontMath.timecentsToSeconds(-12000)
        let env = VolumeEnvelope(sampleRate: sampleRate, blockSize: 64)
        env.start(delay: instant, attack: instant, hold: 10, decay: 10, sustain: 1, release: 1)
        env.process()
        env.process()
        #expect(env.value > 0.9, "delay+attack of ~1 ms each must complete within the first two blocks")
    }
}
