import Foundation

/// Numeric conversion helpers used throughout the SoundFont loader and the
/// DSP voice chain (envelopes, oscillator, filter).
///
/// Ported from `SoundFontMath.cs` (MeltySynth, MIT License — see NOTICE).
internal enum SoundFontMath {
    internal static let halfPi: Float = Float.pi / 2

    internal static let nonAudible: Float = 1.0e-3

    /// Log-domain cutoff used by `expCutoff`. Kept in `Double` (not `Float`) to
    /// match the C# `private static readonly double logNonAudible` exactly —
    /// `expCutoff` itself operates in `Double`.
    private static let logNonAudible: Double = Foundation.log(1.0e-3)

    internal static func timecentsToSeconds(_ x: Float) -> Float {
        pow(2 as Float, (1 as Float / 1200) * x)
    }

    internal static func centsToHertz(_ x: Float) -> Float {
        8.176 * pow(2 as Float, (1 as Float / 1200) * x)
    }

    internal static func centsToMultiplyingFactor(_ x: Float) -> Float {
        pow(2 as Float, (1 as Float / 1200) * x)
    }

    internal static func decibelsToLinear(_ x: Float) -> Float {
        pow(10 as Float, 0.05 * x)
    }

    internal static func linearToDecibels(_ x: Float) -> Float {
        20 * log10(x)
    }

    internal static func keyNumberToMultiplyingFactor(_ cents: Int, _ key: Int) -> Float {
        timecentsToSeconds(Float(cents * (60 - key)))
    }

    internal static func expCutoff(_ x: Double) -> Double {
        if x < logNonAudible {
            return 0.0
        } else {
            return exp(x)
        }
    }
}
