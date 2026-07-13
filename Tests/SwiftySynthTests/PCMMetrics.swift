import Foundation

/// §7 acceptance metrics. All accumulation in Double.
enum PCMMetrics {
    static func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        var m = 0.0
        for i in a.indices {
            m = max(m, abs(Double(a[i]) - Double(b[i])))
        }
        return m
    }

    static func rms<S: Sequence>(_ xs: S) -> Double where S.Element == Double {
        var sum = 0.0
        var n = 0
        for x in xs {
            sum += x * x
            n += 1
        }
        return n == 0 ? 0 : (sum / Double(n)).squareRoot()
    }

    /// Worst RMS over every full `window`-sample window at hop `hop` (trailing partial
    /// window excluded by definition).
    static func worstWindowRMS(error: [Double], window: Int = 4_096, hop: Int = 2_048) -> Double {
        guard error.count >= window else { return rms(error) }
        var worst = 0.0
        var start = 0
        while start + window <= error.count {
            worst = max(worst, rms(error[start..<(start + window)]))
            start += hop
        }
        return worst
    }

    /// 20·log10(RMS(ref)/RMS(err)); +∞ for a bit-exact match.
    static func snr(reference: [Float], error: [Double]) -> Double {
        let refRMS = rms(reference.lazy.map(Double.init))
        let errRMS = rms(error)
        guard errRMS > 0 else { return .infinity }
        return 20 * log10(refRMS / errRMS)
    }

    /// Zero-lag normalized cross-correlation — NO lag search, by spec.
    static func zeroLagCorrelation(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in a.indices {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            aa += x * x
            bb += y * y
        }
        guard aa > 0, bb > 0 else { return aa == bb ? 1 : 0 }
        return dot / (aa.squareRoot() * bb.squareRoot())
    }
}
