import Foundation

/// Stereo chorus: two delay lines read through slowly LFO-modulated
/// fractional taps (sine table, right tap a quarter cycle ahead), linear
/// interpolation in Double.
///
/// Ported from `Chorus.cs` (MeltySynth, MIT License — see NOTICE).
/// FAITHFUL (full-port spec §3, §5d): the buffer/table sizing casts, the
/// Double-width interpolation, the read-before-write order, and all three
/// wraparounds are transliterated exactly. `Synthesizer` constructs this
/// with the canonical (delay: 0.002, depth: 0.0019, frequency: 0.4).
final class Chorus {
    private var bufferL: [Float]
    private var bufferR: [Float]

    private let delayTable: [Float]

    private var bufferIndex = 0

    private var delayTableIndexL: Int
    private var delayTableIndexR: Int

    init(sampleRate: Int, delay: Double, depth: Double, frequency: Double) {
        // C# `(int)(sampleRate * (delay + depth)) + 2` — TRUNCATION, not
        // rounding (173 samples at the canonical 44.1 kHz parameters).
        let bufferSize = Int(Double(sampleRate) * (delay + depth)) + 2
        bufferL = [Float](repeating: 0, count: bufferSize)
        bufferR = [Float](repeating: 0, count: bufferSize)

        // C# `(int)Math.Round(sampleRate / frequency)` — banker's rounding
        // (110250 exactly at 44.1 kHz / 0.4 Hz; one full LFO cycle,
        // ~441 KB — allocated once, here). Values are computed in Double
        // and narrowed to Float per entry, exactly as C#.
        let tableSize = Int((Double(sampleRate) / frequency).rounded(.toNearestOrEven))
        var delayTable = [Float](repeating: 0, count: tableSize)
        for t in 0..<tableSize {
            let phase = 2 * Double.pi * Double(t) / Double(tableSize)
            delayTable[t] = Float(Double(sampleRate) * (delay + depth * sin(phase)))
        }
        self.delayTable = delayTable

        delayTableIndexL = 0
        delayTableIndexR = tableSize / 4
    }

    /// Mirrors `Chorus.Process`: per sample — read both fractionally
    /// delayed taps (interpolating in Double), advance both table indexes,
    /// THEN write the current inputs and advance the ring buffer.
    func process(inputLeft: [Float], inputRight: [Float],
                 outputLeft: inout [Float], outputRight: inout [Float]) {
        for t in 0..<outputLeft.count {
            do {
                var position = Double(bufferIndex) - Double(delayTable[delayTableIndexL])
                if position < 0 {
                    position += Double(bufferL.count)
                }

                let index1 = Int(position)
                var index2 = index1 + 1

                if index2 == bufferL.count {
                    index2 = 0
                }

                let x1 = Double(bufferL[index1])
                let x2 = Double(bufferL[index2])
                let a = position - Double(index1)
                outputLeft[t] = Float(x1 + a * (x2 - x1))

                delayTableIndexL += 1
                if delayTableIndexL == delayTable.count {
                    delayTableIndexL = 0
                }
            }

            do {
                var position = Double(bufferIndex) - Double(delayTable[delayTableIndexR])
                if position < 0 {
                    position += Double(bufferR.count)
                }

                let index1 = Int(position)
                var index2 = index1 + 1

                if index2 == bufferR.count {
                    index2 = 0
                }

                let x1 = Double(bufferR[index1])
                let x2 = Double(bufferR[index2])
                let a = position - Double(index1)
                outputRight[t] = Float(x1 + a * (x2 - x1))

                delayTableIndexR += 1
                if delayTableIndexR == delayTable.count {
                    delayTableIndexR = 0
                }
            }

            bufferL[bufferIndex] = inputLeft[t]
            bufferR[bufferIndex] = inputRight[t]
            bufferIndex += 1
            if bufferIndex == bufferL.count {
                bufferIndex = 0
            }
        }
    }

    /// Mirrors `Chorus.Mute`: clears the delay lines only (the ring and
    /// table indexes intentionally keep their phase, per C#).
    func mute() {
        for i in 0..<bufferL.count {
            bufferL[i] = 0
        }
        for i in 0..<bufferR.count {
            bufferR[i] = 0
        }
    }
}
