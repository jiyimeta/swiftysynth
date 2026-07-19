import Foundation

/// Live render-cost statistics. `record` is called on the audio thread;
/// `snapshot` on the UI thread. Display-only benign race on 64-bit-aligned
/// scalars (same rationale as the spike's RenderHarness); never blocks audio.
final class RenderStats: @unchecked Sendable {
    /// Real-time budget: nanoseconds available per output frame.
    let deadlineNanosPerFrame: Double

    private var smoothed: Double = 0        // EMA of ns/frame
    private var maxPerFrame: Double = 0
    private var activeVoices: Int = 0

    init(sampleRate: Int) {
        deadlineNanosPerFrame = 1_000_000_000.0 / Double(sampleRate)
    }

    func record(nanos: UInt64, frames: Int, activeVoices: Int) {
        guard frames > 0 else { return }
        let perFrame = Double(nanos) / Double(frames)
        smoothed = smoothed == 0 ? perFrame : (smoothed * 0.9 + perFrame * 0.1)
        if perFrame > maxPerFrame { maxPerFrame = perFrame }
        self.activeVoices = activeVoices
    }

    func resetMax() { maxPerFrame = 0 }

    struct Snapshot {
        var currentPercent: Double
        var maxPercent: Double
        var activeVoices: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(
            currentPercent: 100 * smoothed / deadlineNanosPerFrame,
            maxPercent: 100 * maxPerFrame / deadlineNanosPerFrame,
            activeVoices: activeVoices)
    }
}
