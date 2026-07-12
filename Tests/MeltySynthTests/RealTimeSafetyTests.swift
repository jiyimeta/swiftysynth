import Foundation
import Testing
@testable import MeltySynth

#if os(macOS)
import AVFoundation

struct SpikeNoteEvent {
    let frame: Int64
    let isOn: Bool
    let key: Int
    let velocity: Int
}

/// Single-owner state handed to the audio render thread. `@unchecked Sendable` is sound
/// here because after `engine.start()` only the render thread touches the mutable fields,
/// and the test thread reads them only after `engine.stop()` (happens-before via stop).
final class SpikeRenderHarness: @unchecked Sendable {
    let synthesizer: Synthesizer
    let events: [SpikeNoteEvent]
    var eventIndex = 0
    var framesRendered: Int64 = 0

    init(synthesizer: Synthesizer, events: [SpikeNoteEvent]) {
        self.synthesizer = synthesizer
        self.events = events
    }
}

enum RenderBlockFactory {
    /// MUST stay `nonisolated static`. A render block formed inside a @MainActor context
    /// inherits MainActor isolation and traps EXC_BREAKPOINT on the audio thread under the
    /// Swift concurrency runtime — and OFFLINE rendering does not reproduce the trap,
    /// which is why this test uses a live AVAudioSourceNode (spec §8).
    nonisolated static func makeSourceNode(harness: SpikeRenderHarness) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard abl.count >= 2,
                  let rawLeft = abl[0].mData,
                  let rawRight = abl[1].mData else {
                return kAudioUnitErr_InvalidParameter
            }
            let left = UnsafeMutableBufferPointer(
                start: rawLeft.assumingMemoryBound(to: Float.self), count: frames)
            let right = UnsafeMutableBufferPointer(
                start: rawRight.assumingMemoryBound(to: Float.self), count: frames)

            // Spike event model (spec §8): events are driven INSIDE the render block by
            // comparing a running frame counter against preplanned event frames.
            while harness.eventIndex < harness.events.count,
                  harness.events[harness.eventIndex].frame <= harness.framesRendered {
                let event = harness.events[harness.eventIndex]
                if event.isOn {
                    harness.synthesizer.noteOn(key: event.key, velocity: event.velocity)
                } else {
                    harness.synthesizer.noteOff(key: event.key)
                }
                harness.eventIndex += 1
            }

            harness.synthesizer.render(left: left, right: right)
            harness.framesRendered += Int64(frames)
            return noErr
        }
    }
}
#endif

@Suite(.serialized)
struct RealTimeSafetyTests {
    #if os(macOS)
    /// **G3 (no-trap)** — ≥5 s of live rendering on a real AVAudioSourceNode render
    /// thread with a factory-built block; surviving to the assertions == zero traps.
    @Test(.enabled(if: FixtureSF2.exists, "GeneralUser GS not present at the locked path"))
    func noTrapOnRenderThread() throws {
        let font = try SoundFont(url: FixtureSF2.url)
        let synth = try Synthesizer(soundFont: font, sampleRate: 44_100)
        let harness = SpikeRenderHarness(
            synthesizer: synth,
            events: [
                SpikeNoteEvent(frame: 0, isOn: true, key: 60, velocity: 100),
                SpikeNoteEvent(frame: 88_200, isOn: false, key: 60, velocity: 0),
                SpikeNoteEvent(frame: 132_300, isOn: true, key: 64, velocity: 90),
                SpikeNoteEvent(frame: 176_400, isOn: false, key: 64, velocity: 0),
            ])
        let node = RenderBlockFactory.makeSourceNode(harness: harness)

        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        engine.mainMixerNode.outputVolume = 0.0   // keep the test silent; the node is still pulled
        try engine.start()
        Thread.sleep(forTimeInterval: 5.5)
        engine.stop()

        #expect(harness.framesRendered >= Int64(5 * 44_100),
                "render thread ran for \(harness.framesRendered) frames; expected ≥ 5 s worth")
        #expect(harness.eventIndex == harness.events.count,
                "all preplanned events must have fired on the render thread")
    }
    #endif
}
