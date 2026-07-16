import Testing
@testable import SwiftySynth

/// Hermetic. `ArrayMath.multiplyAdd` is the effects-return accumulate
/// (`block += masterVolume * effectsOutput`). Small exact-arithmetic vectors:
/// every value below is exactly representable in Float, so `==` is the right
/// assertion — any reordering/fma deviation would still pass (per-element
/// independence), but a wrong loop bound or a `=` instead of `+=` fails.
struct ArrayMathTests {
    @Test func multiplyAddAccumulatesInPlace() {
        var destination: [Float] = [1, 2, 3, 4]
        ArrayMath.multiplyAdd(2, [10, 20, 30, 40], &destination)
        #expect(destination == [21, 42, 63, 84])
    }

    @Test func multiplyAddWithZeroGainIsIdentity() {
        var destination: [Float] = [1, -2, 3.5, 0]
        ArrayMath.multiplyAdd(0, [5, 6, 7, 8], &destination)
        #expect(destination == [1, -2, 3.5, 0])
    }

    @Test func multiplyAddWithNegativeGain() {
        var destination: [Float] = [10, 10]
        ArrayMath.multiplyAdd(-0.5, [4, 8], &destination)
        #expect(destination == [8, 6])
    }
}
