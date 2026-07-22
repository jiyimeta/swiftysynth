import Foundation
import SwiftySynth

/// Audio-thread-owned rendering core: N (Synthesizer, MidiFileSequencer) layers,
/// each looping the same MIDI (transposed for k > 0) and summed into the output.
/// Built on the main thread while the engine is stopped; only the audio thread
/// touches it after start. Allocation-free in `render`.
final class RenderCore: @unchecked Sendable {
    struct Layer { let synth: Synthesizer; let sequencer: MidiFileSequencer }

    let layers: [Layer]
    let stats: RenderStats

    private var scratchL: [Float]
    private var scratchR: [Float]

    /// Semitone offsets so stacked layers don't phase-cancel and are audibly
    /// thicker. Index 0 is the unmodified song.
    static let transposeOffsets = [0, 7, -5, 12, -12, 4, -7, 5]

    init(soundFont: SoundFont, midiFile: MidiFile, layerCount: Int,
         sampleRate: Int, maxFrames: Int, enableModulators: Bool) throws {
        var built: [Layer] = []
        for k in 0..<max(1, layerCount) {
            let settings = try SynthesizerSettings(
                sampleRate: sampleRate, enableModulators: enableModulators)
            let synth = try Synthesizer(soundFont: soundFont, settings: settings)
            let sequencer = MidiFileSequencer(synthesizer: synth)
            let offset = RenderCore.transposeOffsets[k % RenderCore.transposeOffsets.count]
            if offset != 0 {
                sequencer.onSend = { synth, channel, command, data1, data2 in
                    var key = data1
                    if command == 0x90 || command == 0x80 {   // note on/off
                        key = min(max(data1 + offset, 0), 127)
                    }
                    synth.processMidiMessage(
                        channel: channel, command: command, data1: key, data2: data2)
                }
            }
            sequencer.play(midiFile, loop: true)
            built.append(Layer(synth: synth, sequencer: sequencer))
        }
        layers = built
        stats = RenderStats(sampleRate: sampleRate)
        scratchL = [Float](repeating: 0, count: maxFrames)
        scratchR = [Float](repeating: 0, count: maxFrames)
    }

    /// Audio thread: render `frames` into the (deinterleaved) output, summed
    /// over layers. No allocation.
    func render(left: UnsafeMutableBufferPointer<Float>,
                right: UnsafeMutableBufferPointer<Float>, frames: Int) {
        for i in 0..<frames { left[i] = 0; right[i] = 0 }
        scratchL.withUnsafeMutableBufferPointer { sl in
            scratchR.withUnsafeMutableBufferPointer { sr in
                let n = min(frames, sl.count)
                for layer in layers {
                    layer.sequencer.render(
                        left: UnsafeMutableBufferPointer(rebasing: sl[0..<n]),
                        right: UnsafeMutableBufferPointer(rebasing: sr[0..<n]))
                    for i in 0..<n { left[i] += sl[i]; right[i] += sr[i] }
                }
            }
        }
    }

    var activeVoices: Int { layers.reduce(0) { $0 + $1.synth.activeVoiceCount } }
}
