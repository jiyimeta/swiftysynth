/// Numeric-critical helper for the effects-return mix
/// (`block += masterVolume × effectsOutput`).
///
/// Ported from `ArrayMath.cs` (MeltySynth, MIT License — see NOTICE).
/// FAITHFUL with one deliberate, numerically-neutral adaptation: C#'s
/// `MultiplyAdd(float, float[], float[])` is SIMD-vectorized
/// (`Vector<float>`), but every destination element is independent
/// (`d[i] += a·x[i]`, no cross-lane accumulation), so this scalar loop —
/// C#'s own commented-out reference implementation — is bit-identical to
/// the vectorized original.
///
/// C#'s second overload (the `a += step` gain RAMP) is intentionally NOT
/// ported here: its Swift form already lives inline in
/// `Synthesizer.writeBlock` (the spike's G2-proven fold-in of both
/// overloads), which the effects send buffers reuse unchanged. Do not
/// duplicate it.
enum ArrayMath {
    /// `destination[i] += a * x[i]` over `destination`'s length.
    /// Callers pass equal-length blocks (`blockSize`).
    static func multiplyAdd(_ a: Float, _ x: [Float], _ destination: inout [Float]) {
        for i in 0..<destination.count {
            destination[i] += a * x[i]
        }
    }
}
