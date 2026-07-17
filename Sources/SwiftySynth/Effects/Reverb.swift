/// Freeverb reverb: per stereo channel, 8 parallel feedback-comb filters
/// summed into a series of 4 allpass filters; the right-channel banks are
/// offset by `stereoSpread` samples.
///
/// Ported from `Reverb.cs` (MeltySynth, MIT License — see NOTICE); the
/// original algorithm is Freeverb by Jezar at Dreampoint (public domain).
///
/// FAITHFUL — Phase 2's standing numeric risk (full-port spec §3, §5d): the
/// comb filters carry feedback state whose FP differences compound over a
/// multi-second tail, so every constant, operation order, denormal guard,
/// and the chunked ring-buffer walk below are transliterated exactly.
/// Do NOT restructure the arithmetic, reorder the banks, or remove the
/// default-settings wet1/wet2 skip.
final class Reverb {
    private static let fixedGain: Float = 0.015
    private static let scaleWet: Float = 3
    private static let scaleDamp: Float = 0.4
    private static let scaleRoom: Float = 0.28
    private static let offsetRoom: Float = 0.7
    private static let initialRoom: Float = 0.5
    private static let initialDamp: Float = 0.5
    private static let initialWet: Float = 1 / Reverb.scaleWet
    private static let initialWidth: Float = 1
    private static let stereoSpread = 23

    private static let cfTuningL1 = 1116
    private static let cfTuningR1 = 1116 + Reverb.stereoSpread
    private static let cfTuningL2 = 1188
    private static let cfTuningR2 = 1188 + Reverb.stereoSpread
    private static let cfTuningL3 = 1277
    private static let cfTuningR3 = 1277 + Reverb.stereoSpread
    private static let cfTuningL4 = 1356
    private static let cfTuningR4 = 1356 + Reverb.stereoSpread
    private static let cfTuningL5 = 1422
    private static let cfTuningR5 = 1422 + Reverb.stereoSpread
    private static let cfTuningL6 = 1491
    private static let cfTuningR6 = 1491 + Reverb.stereoSpread
    private static let cfTuningL7 = 1557
    private static let cfTuningR7 = 1557 + Reverb.stereoSpread
    private static let cfTuningL8 = 1617
    private static let cfTuningR8 = 1617 + Reverb.stereoSpread
    private static let apfTuningL1 = 556
    private static let apfTuningR1 = 556 + Reverb.stereoSpread
    private static let apfTuningL2 = 441
    private static let apfTuningR2 = 441 + Reverb.stereoSpread
    private static let apfTuningL3 = 341
    private static let apfTuningR3 = 341 + Reverb.stereoSpread
    private static let apfTuningL4 = 225
    private static let apfTuningR4 = 225 + Reverb.stereoSpread

    private let cfsL: [CombFilter]
    private let cfsR: [CombFilter]
    private let apfsL: [AllPassFilter]
    private let apfsR: [AllPassFilter]

    private var gain: Float = 0
    private var roomSizeValue: Float = 0
    private var roomSize1: Float = 0
    private var dampValue: Float = 0
    private var damp1: Float = 0
    private var wetValue: Float = 0
    private var wet1: Float = 0
    private var wet2: Float = 0
    private var widthValue: Float = 0

    init(sampleRate: Int) {
        cfsL = [
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL1)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL2)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL3)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL4)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL5)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL6)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL7)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningL8)),
        ]

        cfsR = [
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR1)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR2)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR3)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR4)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR5)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR6)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR7)),
            CombFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.cfTuningR8)),
        ]

        apfsL = [
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningL1)),
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningL2)),
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningL3)),
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningL4)),
        ]

        apfsR = [
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningR1)),
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningR2)),
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningR3)),
            AllPassFilter(bufferSize: Reverb.scaleTuning(sampleRate, Reverb.apfTuningR4)),
        ]

        for apf in apfsL {
            apf.feedback = 0.5
        }
        for apf in apfsR {
            apf.feedback = 0.5
        }

        wet = Reverb.initialWet
        roomSize = Reverb.initialRoom
        damp = Reverb.initialDamp
        width = Reverb.initialWidth
    }

    /// C# `(int)Math.Round((double)sampleRate / 44100 * tuning)` —
    /// Math.Round(double) is round-half-to-EVEN (banker's), hence
    /// `.toNearestOrEven`, NOT `.rounded()`. (rustysynth rounds half away
    /// from zero here — a real divergence at non-44.1 kHz rates with .5
    /// midpoints; all committed gate vectors are 44.1 kHz where the ratio
    /// is 1 and no rounding occurs. ReverbTests pins this at 22050 Hz.)
    private static func scaleTuning(_ sampleRate: Int, _ tuning: Int) -> Int {
        Int((Double(sampleRate) / 44_100 * Double(tuning)).rounded(.toNearestOrEven))
    }

    /// Mirrors `Reverb.Process`: mono send in, stereo tail out. The outputs
    /// are cleared first (the combs ADD); allpasses then run in series in
    /// place; the wet1/wet2 rotation is skipped at the default settings.
    func process(input: [Float], outputLeft: inout [Float], outputRight: inout [Float]) {
        for i in 0..<outputLeft.count {
            outputLeft[i] = 0
        }
        for i in 0..<outputRight.count {
            outputRight[i] = 0
        }

        for cf in cfsL {
            cf.process(input: input, output: &outputLeft)
        }
        for apf in apfsL {
            apf.process(block: &outputLeft)
        }
        for cf in cfsR {
            cf.process(input: input, output: &outputRight)
        }
        for apf in apfsR {
            apf.process(block: &outputRight)
        }

        // With the default settings, we can skip this part.
        if 1 - wet1 > 1.0e-3 || wet2 > 1.0e-3 {
            for t in 0..<input.count {
                let left = outputLeft[t]
                let right = outputRight[t]
                outputLeft[t] = left * wet1 + right * wet2
                outputRight[t] = right * wet1 + left * wet2
            }
        }
    }

    /// Mirrors `Reverb.Mute`: clears every filter's recirculating state.
    func mute() {
        for cf in cfsL {
            cf.mute()
        }
        for cf in cfsR {
            cf.mute()
        }
        for apf in apfsL {
            apf.mute()
        }
        for apf in apfsR {
            apf.mute()
        }
    }

    /// Mirrors `Reverb.Update`: recomputes the derived wet/room/damp state
    /// and pushes feedback/damp into every comb. Runs on every parameter set.
    private func update() {
        wet1 = wetValue * (widthValue / 2 + 0.5)
        wet2 = wetValue * ((1 - widthValue) / 2)

        roomSize1 = roomSizeValue
        damp1 = dampValue
        gain = Reverb.fixedGain

        for cf in cfsL {
            cf.feedback = roomSize1
            cf.damp = damp1
        }
        for cf in cfsR {
            cf.feedback = roomSize1
            cf.damp = damp1
        }
    }

    /// The fixed input gain the SEND path multiplies by (`Reverb.InputGain`).
    var inputGain: Float { gain }

    var roomSize: Float {
        get { (roomSizeValue - Reverb.offsetRoom) / Reverb.scaleRoom }
        set {
            roomSizeValue = (newValue * Reverb.scaleRoom) + Reverb.offsetRoom
            update()
        }
    }

    var damp: Float {
        get { dampValue / Reverb.scaleDamp }
        set {
            dampValue = newValue * Reverb.scaleDamp
            update()
        }
    }

    var wet: Float {
        get { wetValue / Reverb.scaleWet }
        set {
            wetValue = newValue * Reverb.scaleWet
            update()
        }
    }

    var width: Float {
        get { widthValue }
        set {
            widthValue = newValue
            update()
        }
    }

    /// Freeverb's lowpass-feedback comb (`Reverb.CombFilter` in C#).
    final class CombFilter {
        private var buffer: [Float]

        private var bufferIndex = 0
        private var filterStore: Float = 0

        var feedback: Float = 0
        private var damp1: Float = 0
        private var damp2: Float = 0

        var damp: Float {
            get { damp1 }
            set {
                damp1 = newValue
                damp2 = 1 - newValue
            }
        }

        init(bufferSize: Int) {
            buffer = [Float](repeating: 0, count: bufferSize)
        }

        func mute() {
            for i in 0..<buffer.count {
                buffer[i] = 0
            }
            filterStore = 0
        }

        func process(input inputBlock: [Float], output outputBlock: inout [Float]) {
            var blockIndex = 0
            while blockIndex < outputBlock.count {
                if bufferIndex == buffer.count {
                    bufferIndex = 0
                }

                let srcRem = buffer.count - bufferIndex
                let dstRem = outputBlock.count - blockIndex
                let rem = min(srcRem, dstRem)

                for t in 0..<rem {
                    let blockPos = blockIndex + t
                    let bufferPos = bufferIndex + t

                    let input = inputBlock[blockPos]

                    // The following ifs are to avoid performance problems due
                    // to denormalized numbers (C# comment retained: the
                    // simple abs-threshold flush outperformed the original
                    // unsafe-cast detection).
                    var output = buffer[bufferPos]
                    if abs(output) < 1.0e-6 {
                        output = 0
                    }

                    filterStore = (output * damp2) + (filterStore * damp1)
                    if abs(filterStore) < 1.0e-6 {
                        filterStore = 0
                    }

                    buffer[bufferPos] = input + (filterStore * feedback)
                    outputBlock[blockPos] += output
                }

                bufferIndex += rem
                blockIndex += rem
            }
        }
    }

    /// Freeverb's allpass primitive (`Reverb.AllPassFilter` in C#).
    final class AllPassFilter {
        private var buffer: [Float]

        private var bufferIndex = 0

        var feedback: Float = 0

        init(bufferSize: Int) {
            buffer = [Float](repeating: 0, count: bufferSize)
        }

        func mute() {
            for i in 0..<buffer.count {
                buffer[i] = 0
            }
        }

        func process(block: inout [Float]) {
            var blockIndex = 0
            while blockIndex < block.count {
                if bufferIndex == buffer.count {
                    bufferIndex = 0
                }

                let srcRem = buffer.count - bufferIndex
                let dstRem = block.count - blockIndex
                let rem = min(srcRem, dstRem)

                for t in 0..<rem {
                    let blockPos = blockIndex + t
                    let bufferPos = bufferIndex + t

                    let input = block[blockPos]

                    var bufout = buffer[bufferPos]
                    if abs(bufout) < 1.0e-6 {
                        bufout = 0
                    }

                    block[blockPos] = bufout - input
                    buffer[bufferPos] = input + (bufout * feedback)
                }

                bufferIndex += rem
                blockIndex += rem
            }
        }
    }
}
