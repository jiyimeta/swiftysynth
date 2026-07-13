import AVFoundation
import Foundation
import SwiftySynth

// MARK: - Render harness

struct NoteEvent {
    let frame: Int64
    let isOn: Bool
    let key: Int
    let velocity: Int
}

/// Single-owner state handed to the audio render thread. `@unchecked Sendable` is sound:
/// after engine.start() only the render thread touches the mutable fields; the main
/// thread reads them after engine.stop().
final class RenderHarness: @unchecked Sendable {
    let synthesizer: Synthesizer
    let events: [NoteEvent]
    var eventIndex = 0
    var framesRendered: Int64 = 0
    var callbackCount = 0
    /// Histogram of render cost in ns-per-frame; bucket width 250 ns, last bucket = overflow.
    var buckets = [Int](repeating: 0, count: 256)
    var maxNanosPerFrame: UInt64 = 0

    init(synthesizer: Synthesizer, events: [NoteEvent]) {
        self.synthesizer = synthesizer
        self.events = events
    }

    func record(nanos: UInt64, frames: Int) {
        guard frames > 0 else { return }
        let perFrame = nanos / UInt64(frames)
        maxNanosPerFrame = max(maxNanosPerFrame, perFrame)
        buckets[min(Int(perFrame / 250), buckets.count - 1)] += 1
        callbackCount += 1
    }

    func percentileNanosPerFrame(_ p: Double) -> UInt64 {
        guard callbackCount > 0 else { return 0 }
        let target = Int((p * Double(callbackCount)).rounded(.up))
        var seen = 0
        for (i, count) in buckets.enumerated() {
            seen += count
            if seen >= target { return UInt64(i + 1) * 250 }
        }
        return maxNanosPerFrame
    }
}

enum MachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func toNanos(_ delta: UInt64) -> UInt64 {
        delta * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

enum RenderBlockFactory {
    /// MUST stay `nonisolated static` — a render block created inside a @MainActor
    /// context (like this file's top-level code) inherits MainActor isolation and traps
    /// EXC_BREAKPOINT on the audio thread. See spec §8.
    nonisolated static func makeSourceNode(harness: RenderHarness) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let start = mach_absolute_time()
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
            harness.record(nanos: MachTime.toNanos(mach_absolute_time() - start), frames: frames)
            return noErr
        }
    }
}

// MARK: - WAV export

func writeFloat32StereoWav(left: [Float], right: [Float], sampleRate: Int, to url: URL) throws {
    precondition(left.count == right.count)
    var out = Data()
    func u16(_ v: UInt16) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8(v >> 8))
    }
    func u32(_ v: UInt32) {
        u16(UInt16(v & 0xFFFF))
        u16(UInt16(v >> 16))
    }
    let dataBytes = UInt32(left.count * 2 * 4)
    out.append(contentsOf: "RIFF".utf8)
    u32(36 + dataBytes)
    out.append(contentsOf: "WAVE".utf8)
    out.append(contentsOf: "fmt ".utf8)
    u32(16)
    u16(3)                                // WAVE_FORMAT_IEEE_FLOAT
    u16(2)
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 8))           // byte rate: 2 ch × 4 bytes
    u16(8)                                // block align
    u16(32)                               // bits per sample
    out.append(contentsOf: "data".utf8)
    u32(dataBytes)
    for i in left.indices {
        u32(left[i].bitPattern)
        u32(right[i].bitPattern)
    }
    try out.write(to: url)
}

// MARK: - Subcommands

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func makeSynthesizer(sf2Path: String) -> Synthesizer {
    do {
        let font = try SoundFont(url: URL(fileURLWithPath: sf2Path))
        return try Synthesizer(soundFont: font, sampleRate: 44_100)
    } catch {
        fail("failed to load \(sf2Path): \(error)")
    }
}

let fixtureEvents = [
    NoteEvent(frame: 0, isOn: true, key: 60, velocity: 100),
    NoteEvent(frame: 88_200, isOn: false, key: 60, velocity: 0),
]

let arguments = CommandLine.arguments
switch arguments.count >= 2 ? arguments[1] : "" {
case "play":
    guard arguments.count >= 3 else { fail("usage: SwiftySynthSpike play <sf2> [seconds]") }
    let seconds = arguments.count >= 4 ? (Double(arguments[3]) ?? 6) : 6
    let harness = RenderHarness(synthesizer: makeSynthesizer(sf2Path: arguments[2]), events: fixtureEvents)
    let node = RenderBlockFactory.makeSourceNode(harness: harness)
    let engine = AVAudioEngine()
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode,
                   format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    do {
        try engine.start()
    } catch {
        fail("engine start failed: \(error)")
    }
    print("playing C4 (noteOff at 2.0 s) live for \(seconds) s ...")
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()

    let deadline = 1e9 / 44_100.0   // ns per frame ≈ 22676
    let p50 = harness.percentileNanosPerFrame(0.50)
    let p99 = harness.percentileNanosPerFrame(0.99)
    print("callbacks: \(harness.callbackCount), frames rendered: \(harness.framesRendered)")
    print(String(
        format: "render cost ns/frame — p50: %d (%.2f%% of deadline), p99: %d (%.2f%%), max: %d (%.2f%%)",
        p50, 100 * Double(p50) / deadline,
        p99, 100 * Double(p99) / deadline,
        harness.maxNanosPerFrame, 100 * Double(harness.maxNanosPerFrame) / deadline))

case "export":
    guard arguments.count == 4 else { fail("usage: SwiftySynthSpike export <sf2> <out.wav>") }
    // `nonisolated(unsafe)`: this top-level script is single-threaded end to end (the
    // "export" case never touches an audio-thread render callback, unlike "play"'s
    // `RenderHarness`), so there is no actual concurrent access to race — but whole-module
    // optimization's region-based isolation checker (release/-wmo builds only) sees this
    // MainActor-isolated top-level `let` used inside nested `withUnsafeMutableBufferPointer`
    // closures alongside the OTHER switch case's genuinely-concurrent nonisolated render
    // block (same `Synthesizer` type, different instance) and flags a possible race that
    // cannot occur here.
    nonisolated(unsafe) let synthesizer = makeSynthesizer(sf2Path: arguments[2])
    var left = [Float](repeating: 0, count: 220_500)
    var right = [Float](repeating: 0, count: 220_500)

    func render(_ range: Range<Int>) {
        left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                synthesizer.render(
                    left: UnsafeMutableBufferPointer(rebasing: lp[range]),
                    right: UnsafeMutableBufferPointer(rebasing: rp[range]))
            }
        }
    }
    // Same two-chunk schedule as the G2 fixture, for by-ear comparison with the oracle WAV.
    synthesizer.noteOn(key: 60, velocity: 100)
    render(0..<88_200)
    synthesizer.noteOff(key: 60)
    render(88_200..<220_500)

    let url = URL(fileURLWithPath: arguments[3])
    do {
        try writeFloat32StereoWav(left: left, right: right, sampleRate: 44_100, to: url)
    } catch {
        fail("wav write failed: \(error)")
    }
    let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
    print("wrote \(url.path) (5.0 s, float32 stereo, peak \(peak))")

default:
    fail("""
    usage: SwiftySynthSpike play <sf2> [seconds]
           SwiftySynthSpike export <sf2> <out.wav>
    """)
}
